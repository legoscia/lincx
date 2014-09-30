-module(linc_max_flow).
-export([
	init/0, mod/1, table_mod/1, name/1, tick/0,
	stats_reply/1, aggregate_stats_reply/1,table_stats_reply/1,
	generate/2
]).

-include_lib("of_protocol/include/of_protocol.hrl").
-include_lib("of_protocol/include/ofp_v4.hrl").
-include_lib("linc/include/linc_logger.hrl").
-include("linc_max.hrl").


init() ->
	%% Generate the module for the first flow table
	generate(0, []).

%% In version 1.3 This doesn't do anything anymore.
table_mod(#ofp_table_mod{}) ->
	ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Flow modifications                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

mod(#ofp_flow_mod{table_id = all, command = Cmd}) when Cmd /= delete andalso Cmd /= delete_strict ->
	{error, {flow_mod_failed, bad_table_id}};
mod(#ofp_flow_mod{
		cookie = Cookie,
		cookie_mask = CookieMask,
		table_id = TableId,
		command = Command,
		idle_timeout = IdleTimeout,
		hard_timeout = HardTimeout,
		priority = Priority,
		out_port = OutPort,
		out_group = OutGroup,
		flags = Flags,
		match = #ofp_match{fields = UnsortedFields},
		instructions = UnsortedInstructions
	}
) ->
	Fields = lists:sort(UnsortedFields),
	Instructions = lists:keysort(2, UnsortedInstructions),

	case Command of
		add ->
			update(
				add(Cookie, Priority, Fields, Instructions, Flags, IdleTimeout, HardTimeout),
				TableId, Priority, Fields, Instructions, [
					match_strict(Priority, Fields)
				]
			);
		modify_strict ->
			update(
				modify(Instructions, Flags),
				TableId, Priority, Fields, Instructions, [
					match_cookie(Cookie, CookieMask),
					match_strict(Priority, Fields)
				]
			);
		modify ->
			update(
				modify(Instructions, Flags),
				TableId, Priority, Fields, Instructions, [
					match_cookie(Cookie, CookieMask),
					match_generic(Fields)
				]
			);
		delete_strict ->
			delete(TableId, Flags, [
				match_cookie(Cookie, CookieMask),
				match_out(OutPort, OutGroup),
				match_strict(Priority, Fields)
			]);
		delete ->
			delete(TableId, Flags, [
				match_cookie(Cookie, CookieMask),
				match_out(OutPort, OutGroup),
				match_generic(Fields)
			])
	end.

update(Method, TableId, Priority, Fields, Instructions, Filters) ->
	try
		Entries = entries(TableId),

		[check_support(F) || F <- Fields],
		[check_mask(F) || F <- Fields],
		[check_value(F) || F <- Fields],
		check_dup(Fields),
		check_prereq(Fields),
		check_overlap(Fields, Entries, Priority),
		check_occurrences(Instructions),
		[check_instruction(I, TableId, Fields) || I <- Instructions],

		{Matched, Keep} = match(partition, TableId, Filters),

		generate(TableId, Method(Matched) ++ Keep)
	catch
		throw:Error ->
			?INFO("Flow update failed: ~p", [Error]),
			{error, Error}
	end.

add(Cookie, Priority, Fields, Instructions, Flags, IdleTimeout, HardTimeout) ->
	Entry = #flow_entry{
		priority = Priority,
		cookie = Cookie,
		install_time = os:timestamp(),
		idle_timeout = IdleTimeout,
		hard_timeout = HardTimeout,
		flags = Flags,
		fields = Fields,
		instructions = Instructions
	},

	fun
		([]) ->
			[Entry#flow_entry{counts = new_entry_counts()}];
		([#flow_entry{counts = Counts}]) ->
			[Entry#flow_entry{counts = reset_counts(Counts, Flags)}]
	end.

modify(Instructions, Flags) ->
	fun(MatchedEntries) ->
		[
			E#flow_entry{
				instructions = Instructions,
				counts = reset_counts(C, Flags)
			} || #flow_entry{counts = C} = E <- MatchedEntries
		]
	end.

delete(Table, Flags, Filters) ->
	lists:foreach(
		fun(Id) ->
			{Delete, Keep} = match(partition, Id, Filters),
			[release_counts(C) || #flow_entry{counts = C} <- Delete],
			case lists:member(send_flow_rem, Flags) of
				true ->
					[send_flow_removed(Id, D, delete) || D <- Delete];
				_ ->
					ok
			end,
			generate(Id, Keep)
		end,
		enum(Table)
	).

send_flow_removed(
	TableId,
	#flow_entry{
		priority = Priority,
		cookie = Cookie,
		install_time = InstallTime,
		hard_timeout = HardTimeout,
		idle_timeout = IdleTimeout,
		fields = Fields,
		counts = Counts
	},
	Reason
) ->
	{Sec, NSec} = duration(InstallTime),
	#flow_entry_counts{
		rx_packets = RxPackets,
		rx_bytes = RxBytes
	} = count(Counts),

	linc_logic:send_to_controllers(
		0, %% SwitchId
		#ofp_message{
			type = ofp_flow_removed,
			body = #ofp_flow_removed{
				priority = Priority,
				cookie = Cookie,
				reason = Reason,
				table_id = TableId,
				duration_sec = Sec,
				duration_nsec = NSec,
				idle_timeout = HardTimeout,
				hard_timeout = IdleTimeout,
				packet_count = RxPackets,
				byte_count = RxBytes,
				match = #ofp_match{fields = Fields}
			}
		}
	).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Flow statistics                          %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

stats(Id, #flow_entry{
	priority = Priority,
	cookie = Cookie,
	install_time = InstallTime,
	flags = Flags,
	fields = Fields,
	instructions = Instructions,
	counts = Counts
}) ->
	{Sec, NSec} = duration(InstallTime),
	#flow_entry_counts{
		rx_packets = RxPackets,
		rx_bytes = RxBytes
	} = count(Counts),

	#ofp_flow_stats{
		table_id = Id,
		duration_sec = Sec,
		duration_nsec = NSec,
		idle_timeout = 0,
		hard_timeout = 0,
		packet_count = RxPackets,
		byte_count = RxBytes,
		priority = Priority,
		cookie = Cookie,
		flags = Flags,
		match = #ofp_match{fields = Fields},
		instructions = Instructions
	}.

stats_reply(
	#ofp_flow_stats_request{
		table_id = Table,
		out_port = OutPort,
		out_group = OutGroup,
		cookie = Cookie,
		cookie_mask = CookieMask,
		match = #ofp_match{fields = Fields}
	}
) ->
	StatsList =
		lists:foldl(
			fun(Id, Acc) ->
				Entries =
					match(filter, Id, [
						match_cookie(Cookie, CookieMask),
						match_out(OutPort, OutGroup),
						match_generic(Fields)
					]),
				Acc ++ [stats(Id, E) || E <- Entries]
			end,
			[],
			enum(Table)
		),
	#ofp_flow_stats_reply{body = StatsList}.

aggregate_stats_reply(
	#ofp_aggregate_stats_request{
		table_id = Table,
		out_port = OutPort,
		out_group = OutGroup,
		cookie = Cookie,
		cookie_mask = CookieMask,
		match = #ofp_match{fields = Fields}
	}
) ->
	Entries =
		match(filter, Table, [
			match_cookie(Cookie, CookieMask),
			match_out(OutPort, OutGroup),
			match_generic(Fields)
		]),

	{Packets, Bytes, Flows} =
		lists:foldl(
			fun(#flow_entry{counts = Counts}, {Packets, Bytes, Flows}) ->
				#flow_entry_counts{
					rx_packets = RxPackets,
					rx_bytes = RxBytes
				} = count(Counts),

				{Packets + RxPackets, Bytes + RxBytes, Flows + 1}
			end,
			{0, 0, 0},
			Entries
		),

	#ofp_aggregate_stats_reply{
		packet_count = Packets,
		byte_count = Bytes,
		flow_count = Flows
	}.

table_stats_reply(#ofp_table_stats_request{}) ->
	TableStats =
		lists:map(
			fun(Id) ->
				Name = name(Id),

				#flow_table_counts{
					packet_lookups = Lookups,
					packet_matches = Matches
				} = count(Name:counts()),

				#ofp_table_stats{
					table_id = Id,
					active_count = erlang:length(Name:entries()),
					lookup_count = Lookups,
					matched_count = Matches
				}
			end,
			enum(all)
		),

	#ofp_table_stats_reply{body = TableStats}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Flow validations                         %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

check_occurrences(Instructions) ->
	Names = [element(1, I) || I <- Instructions],
	case length(lists:usort(Names)) == length(Instructions) of
		true ->
			ok;
		_ ->
			%% There is no suitable error code
			throw({bad_instruction, unknown_inst})
	end.

check_instruction(Instruction, TableId, Fields) ->
	case Instruction of
		#ofp_instruction_meter{meter_id = _MeterId} ->
			%% linc_max_meter:is_valid(MeterId)
			%% There is not suitable error code
			throw({bad_instruction, unsup_inst});
		#ofp_instruction_goto_table{table_id=NextTableId} 
			when TableId < NextTableId, TableId < ?OFPTT_MAX ->
			ok;
		#ofp_instruction_goto_table{} ->
			throw({bad_instruction, bad_table_id});
		#ofp_instruction_write_metadata{} ->
			ok;
		#ofp_instruction_write_actions{actions = Actions} ->
			[check_action(A, Fields) || A <- Actions];
		#ofp_instruction_apply_actions{actions = Actions} ->
			[check_action(A, Fields) || A <- Actions];
		#ofp_instruction_clear_actions{} ->
			ok;
		#ofp_instruction_experimenter{} ->
			throw({bad_instruction, unknown_inst});
		_ ->
			throw({bad_instruction, unknown_inst})
	end.

check_action(Action, Fields) ->
	case Action of
		#ofp_action_output{port=controller,max_len=MaxLen} ->
			%% no_buffer represents OFPCML_NO_BUFFER (0xFFFF)
			if_throw(
				MaxLen /= no_buffer andalso MaxLen > ?OFPCML_MAX,
				{bad_action,bad_argument}
			);
		#ofp_action_output{port=Port} ->
			SwitchId = 0,
			if_throw(
				not linc_max_port:is_valid(SwitchId, Port),
				{bad_action,bad_out_port}
			);
		#ofp_action_group{group_id=GroupId} ->
			SwitchId = 0,
			if_throw(
				not linc_max_groups:is_valid(SwitchId, GroupId),
				{bad_action,bad_out_group}
			);
		#ofp_action_set_queue{} ->
			ok;
		#ofp_action_set_mpls_ttl{} ->
			ok;
		#ofp_action_dec_mpls_ttl{} ->
			ok;
		#ofp_action_set_nw_ttl{} ->
			ok;
		#ofp_action_dec_nw_ttl{} ->
			ok;
		#ofp_action_copy_ttl_out{} ->
			ok;
		#ofp_action_copy_ttl_in{} ->
			ok;
		#ofp_action_push_vlan{ethertype=Ether} ->
			if_throw(
				Ether /= 16#8100 andalso Ether /= 16#88A8,
				{bad_action,bad_argument}
			);
		#ofp_action_pop_vlan{} ->
			ok;
		#ofp_action_push_mpls{ethertype=Ether} ->
			if_throw(
				Ether /= 16#8847 andalso Ether /= 16#8848,
				{bad_action,bad_argument}
			);
		#ofp_action_pop_mpls{} ->
			ok;
		#ofp_action_push_pbb{ethertype=Ether} ->
			if_throw(
				Ether /= 16#88E7,
				{bad_action,bad_argument}
			);
		#ofp_action_pop_pbb{} ->
			ok;
		#ofp_action_set_field{field=Field} ->
			try
				check_prereq([Field], Fields, Fields)
			catch _:_ ->
				throw({bad_action,bad_argument})
			end;
		#ofp_action_experimenter{} ->
			throw({bad_action,bad_type})
	end.

check_support(#ofp_field{class = openflow_basic}) ->
	ok;
check_support(_) ->
	throw({bad_match, bad_field}).

%% Check that field value is in the allowed domain
%% TODO: throw({bad_match, bad_value})
check_value(#ofp_field{name=_Name,value=_Value}) ->
	ok.

%% Check that the mask is correct for the given value
check_mask(#ofp_field{has_mask = true, value = Value, mask = Mask}) ->
	check_mask(Value, Mask);
check_mask(#ofp_field{has_mask = false}) ->
	ok.

check_mask(<<0:1, Value/bitstring>>, <<_:1, Mask/bitstring>>) ->
	check_mask(Value, Mask);
check_mask(<<1:1, Value/bitstring>>, <<1:1, Mask/bitstring>>) ->
	check_mask(Value, Mask);
check_mask(<<>>, <<>>) ->
	ok;
check_mask(_, _) ->
	throw({bad_match, bad_wildcards}).

%% Check that there is no duplicate fields
check_dup(Fields) ->
	check_dup([], [], Fields).

check_dup(_, [], []) ->
	ok;
check_dup(_, [], [Field | Rest]) ->
	check_dup(Field, Rest, Rest);
check_dup(#ofp_field{class=C,name=N}, [#ofp_field{class=C,name=N} | _], _) ->
	throw({bad_match, dup_field});
check_dup(Field, [_ | Rest], All) ->
	check_dup(Field, Rest, All).

%% Check that all field prerequisites are met
check_prereq(Fields) ->
	check_prereq(Fields, Fields, Fields).

-define(CHECK_PREREQ(N), check_prereq([#ofp_field{name=N}|R],_,A) -> check_prereq(R,A,A)).
-define(CHECK_PREREQ(N,M), check_prereq([#ofp_field{name=N}|R],[#ofp_field{name=M}|_], A) -> check_prereq(R,A,A)).
-define(CHECK_PREREQ(N,M,V), check_prereq([#ofp_field{name=N}|R],[#ofp_field{name=M,value= V}|_],A) -> check_prereq(R,A,A)).

?CHECK_PREREQ(in_port);
?CHECK_PREREQ(metadata);
?CHECK_PREREQ(eth_dst);
?CHECK_PREREQ(eth_src);
?CHECK_PREREQ(eth_type);
?CHECK_PREREQ(vlan_vid);
?CHECK_PREREQ(tunnel_id);
?CHECK_PREREQ(in_phy_port   , in_port);
?CHECK_PREREQ(vlan_pcp      , vlan_vid);
?CHECK_PREREQ(ip_dscp       , eth_type   , <<16#800:16>>);
?CHECK_PREREQ(ip_dscp       , eth_type   , <<16#86dd:16>>);
?CHECK_PREREQ(ip_ecn        , eth_type   , <<16#800:16>>);
?CHECK_PREREQ(ip_ecn        , eth_type   , <<16#86dd:16>>);
?CHECK_PREREQ(ip_proto      , eth_type   , <<16#800:16>>);
?CHECK_PREREQ(ip_proto      , eth_type   , <<16#86dd:16>>);
?CHECK_PREREQ(ipv4_src      , eth_type   , <<16#800:16>>);
?CHECK_PREREQ(ipv4_dst      , eth_type   , <<16#800:16>>);
?CHECK_PREREQ(tcp_src       , ip_proto   , <<6:8>>);
?CHECK_PREREQ(tcp_dst       , ip_proto   , <<6:8>>);
?CHECK_PREREQ(udp_src       , ip_proto   , <<17:8>>);
?CHECK_PREREQ(udp_dst       , ip_proto   , <<17:8>>);
?CHECK_PREREQ(sctp_src      , ip_proto   , <<132:8>>);
?CHECK_PREREQ(sctp_dst      , ip_proto   , <<132:8>>);
?CHECK_PREREQ(icmpv4_type   , ip_proto   , <<1:8>>);
?CHECK_PREREQ(icmpv4_code   , ip_proto   , <<1:8>>);
?CHECK_PREREQ(arp_op        , eth_type   , <<16#806:16>>);
?CHECK_PREREQ(arp_spa       , eth_type   , <<16#806:16>>);
?CHECK_PREREQ(arp_tpa       , eth_type   , <<16#806:16>>);
?CHECK_PREREQ(arp_sha       , eth_type   , <<16#806:16>>);
?CHECK_PREREQ(arp_tha       , eth_type   , <<16#806:16>>);
?CHECK_PREREQ(ipv6_src      , eth_type   , <<16#86dd:16>>);
?CHECK_PREREQ(ipv6_dst      , eth_type   , <<16#86dd:16>>);
?CHECK_PREREQ(ipv6_flabel   , eth_type   , <<16#86dd:16>>);
?CHECK_PREREQ(icmpv6_type   , ip_proto   , <<58:8>>);
?CHECK_PREREQ(icmpv6_code   , ip_proto   , <<58:8>>);
?CHECK_PREREQ(ipv6_nd_target, icmpv6_type, <<135:8>>);
?CHECK_PREREQ(ipv6_nd_target, icmpv6_type, <<136:8>>);
?CHECK_PREREQ(ipv6_nd_sll   , icmpv6_type, <<135:8>>);
?CHECK_PREREQ(ipv6_nd_tll   , icmpv6_type, <<136:8>>);
?CHECK_PREREQ(mpls_label    , eth_type   , <<16#8847:16>>);
?CHECK_PREREQ(mpls_label    , eth_type   , <<16#8848:16>>);
?CHECK_PREREQ(mpls_tc       , eth_type   , <<16#8847:16>>);
?CHECK_PREREQ(mpls_tc       , eth_type   , <<16#8848:16>>);
?CHECK_PREREQ(mpls_bos      , eth_type   , <<16#8847:16>>);
?CHECK_PREREQ(mpls_bos      , eth_type   , <<16#8848:16>>);
?CHECK_PREREQ(pbb_isid      , eth_type   , <<16#88e7:16>>);
?CHECK_PREREQ(ipv6_exthdr   , eth_type   , <<16#86dd:16>>);
check_prereq(Fields, [_ | Rest], All) -> check_prereq(Fields, Rest, All);
check_prereq([], _, _) -> ok;
check_prereq(_, [], _) -> throw({bad_match, bad_prereq}).

check_overlap(Fields, Entries, Priority) ->
	%% {flow_mod_failed, overlap}
	lists:any(
		fun(F) ->
			overlaps(Fields, F)
		end,
		[F || #flow_entry{priority=P, fields=F} <- Entries, P == Priority]
	).

overlaps(
	[#ofp_field{class=C,name=F,has_mask=false,value=V}|Fields1],
	[#ofp_field{class=C,name=F,has_mask=false,value=V}|Fields2]
) ->
	overlaps(Fields1,Fields2);
overlaps(
	[#ofp_field{class=C,name=F,has_mask=false,value=V1}|_Fields1],
	[#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2]
) when V1 =/= V2 ->
	false;
overlaps(
	[#ofp_field{class=C,name=F,has_mask=true,value=V1,mask=MaskBin}|_Fields1],
	[#ofp_field{class=C,name=F,has_mask=false,value=V2}|_Fields2]
) ->
	match_mask(V1, V2, MaskBin);
overlaps(
	[#ofp_field{class=C,name=F,has_mask=false,value=V1}|_Fields1],
	[#ofp_field{class=C,name=F,has_mask=true,value=V2,mask=MaskBin}|_Fields2]
) ->
	match_mask(V1, V2, MaskBin);
overlaps(
	[#ofp_field{class=C,name=F,has_mask=true,value=V1,mask=M1}|Fields1],
	[#ofp_field{class=C,name=F,has_mask=true,value=V2,mask=M2}|Fields2]
) ->
	Bits = bit_size(M1),
	<<Val1:Bits>> = V1,
	<<Val2:Bits>> = V2,
	<<Mask1:Bits>> = M1,
	<<Mask2:Bits>> = M2,
	CommonBits = Mask1 band Mask2,
	%% Is this correct?
	case (Val1 band CommonBits) == (Val2 band CommonBits) of
		false ->
			false;
		true ->
			overlaps(Fields1, Fields2)
	end;
overlaps(
	[#ofp_field{class=C, name=F1} | Fields1],
	[#ofp_field{class=C, name=F2} | _] = Fields2
) when F1 < F2 ->
	%% Both lists of match fields have been sorted, so this actually works.
	overlaps(Fields1, Fields2);
overlaps(
	[#ofp_field{class=C,name=F1} | _] = Fields1,
	[#ofp_field{class=C,name=F2} | Fields2]
) when F1 > F2 ->
	%% Both lists of match fields have been sorted, so this actually works.
	overlaps(Fields1, Fields2);
overlaps(_V1, _V2) ->
	true.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Flow matching                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

match(ListsFunction, Table, Filters) ->
	lists:ListsFunction(
		fun(Entry) ->
			lists:all(
				fun(Filter) ->
					Filter(Entry)
				end,
				Filters
			)
		end,
		entries(Table)
	).

match_out(Port, Group) ->
	fun(#flow_entry{instructions = Instructions}) ->
		match_out(Port, Group, Instructions)
	end.

match_out(any, any, _Instructions) ->
	true;
match_out(Port, Group, [#ofp_instruction_write_actions{actions=Actions} | Instructions]) ->
	match_out_actions(Port, Group, Actions) orelse match_out(Port, Group, Instructions);
match_out(Port, Group, [#ofp_instruction_apply_actions{actions=Actions} | Instructions]) ->
	match_out_actions(Port, Group, Actions) orelse match_out(Port, Group, Instructions);
match_out(Port, Group, [_ | Instructions]) ->
	match_out(Port, Group, Instructions);
match_out(_Port, _Group, []) ->
	false.

match_out_actions(Port, _Group, [#ofp_action_output{port=Port} | _]) ->
	true;
match_out_actions(_Port, Group, [#ofp_action_group{group_id=Group} | _]) ->
	true;
match_out_actions(Port, Group, [_ | Actions]) ->
	match_out_actions(Port, Group, Actions);
match_out_actions(_Port, _Group, []) ->
	false.

match_cookie(Cookie, CookieMask) ->
	fun(#flow_entry{cookie = C}) ->
		match_mask(C, Cookie, CookieMask)
	end.

match_strict(Priority, Fields) ->
	fun(#flow_entry{priority = P, fields = F}) ->
		P == Priority andalso F == Fields
	end.

match_generic(Fields) ->
	fun(#flow_entry{fields = EntryFields}) ->
		lists:all(
			fun(F) ->
				lists:any(
					fun(E) ->
						is_more_specific(E, F)
					end,
					EntryFields
				)
			end,
			Fields
		)
	end.

is_more_specific(
	#ofp_field{name = N, has_mask = true},
	#ofp_field{name = N, has_mask = false}
) ->
	false; %% masked is less specific than non-masked
is_more_specific(
	#ofp_field{name = N, has_mask = false, value = V},
	#ofp_field{name = N, has_mask = _____, value = V}
) ->
	true; %% value match with no mask is more specific
is_more_specific(
	#ofp_field{name = N, has_mask = true, mask = M1, value = V1},
	#ofp_field{name = N, has_mask = true, mask = M2, value = V2}
) ->
	%% M1 is more specific than M2 (has all of it's bits)
	%% and V1*M2 == V2*M2
	Bits = bit_size(M1),
	<<Mask1:Bits>> = M1,
	<<Mask2:Bits>> = M2,
	(Mask1 bor Mask2 == Mask1) andalso match_mask(V1, V2, M2);
is_more_specific(_, _) ->
	false.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Counts                                   %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new_entry_counts() ->
	#flow_entry_counts{
		rx_packets = erlang:new_counter(),
		rx_bytes = erlang:new_counter()
	}.

new_table_counts() ->
	#flow_table_counts{
		packet_lookups = erlang:new_counter(),
		packet_matches = erlang:new_counter()
	}.

release_counts(#flow_entry_counts{rx_packets = RxPackets, rx_bytes = RxBytes}) ->
	erlang:release_counter(RxPackets),
	erlang:release_counter(RxBytes).

reset_counts(#flow_entry_counts{} = Counts, Flags) ->
	case lists:member(reset_counts, Flags) of
		true ->
			release_counts(Counts),
			new_entry_counts();
		false ->
			Counts
	end.

count(#flow_entry_counts{rx_packets = RxPackets, rx_bytes = RxBytes}) ->
	#flow_entry_counts{
		rx_packets = erlang:read_counter(RxPackets),
		rx_bytes = erlang:read_counter(RxBytes)
	};
count(#flow_table_counts{packet_lookups = Lookups, packet_matches = Matches}) ->
	#flow_table_counts{
		packet_lookups = erlang:read_counter(Lookups),
		packet_matches = erlang:read_counter(Matches)
	}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                          Misc helpers                             %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

duration(InstallTime) ->
	Duration = timer:now_diff(os:timestamp(), InstallTime),
	Sec = Duration div 1000000,
	NSec = Duration rem 1000000 * 1000,
	{Sec, NSec}.

if_throw(true, Error) ->
	throw(Error);
if_throw(false, _) ->
	ok.

match_mask(Bin1, Bin2, MaskBin) ->
	Bits = bit_size(Bin1),
	<<Val1:Bits>> = Bin1,
	<<Val2:Bits>> = Bin2,
	<<Mask:Bits>> = MaskBin,
	Val1 band Mask == Val2 band Mask.

name(Id) ->
	list_to_atom(lists:concat([flow_,Id])).

entries(Table) ->
	lists:foldl(
		fun(Id, Entries) ->
			Module = name(Id),
			case code:is_loaded(Module) of
				false ->
					Entries;
				_ ->
					Entries ++ Module:entries()
			end
		end,
		[],
		enum(Table)
	).

enum(all) ->
	lists:foldl(
		fun({Module, _}, Ids) ->
			case string:tokens(atom_to_list(Module), "_") of
				["flow", Id] ->
					[list_to_integer(Id) | Ids];
				_ ->
					Ids
			end
		end,
		[],
		code:all_loaded()
	);
enum(Id) ->
	[Id].

generate(TableId, Entries) ->
	Name = name(TableId),
	Counts =
		case code:is_loaded(Name) of
			true ->
				Name:counts();
			_ ->
				new_table_counts()
		end,

	Forms = linc_max_generator:flow_table_forms(
		Name,
		lists:keysort(#flow_entry.priority, Entries),
		Counts
	),

	%[io:format(erl_pp:form(F)) || F <- Forms],
	{ok,Name,Bin} = compile:forms(Forms, [report_errors]),
	%io:format("Compiled\n"),

	case erlang:check_old_code(Name) of
		true ->
			erlang:purge_module(Name);
		_ ->
			ok
	end,

	{module,_} = code:load_binary(Name, "generated", Bin),
	ok.

tick() ->
	Now = os:timestamp(),
	lists:foreach(
		fun(TableId) ->
			{_Expired, Keep} =
				lists:partition(
					fun(#flow_entry{install_time = InstallTime, hard_timeout = HardTimeout}) ->
						timer:now_diff(Now, InstallTime) > HardTimeout
					end,
					entries(TableId)
				),
			generate(TableId, Keep)
		end,
		enum(all)
	).

%%EOF
