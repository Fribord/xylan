%%%---- BEGIN COPYRIGHT -------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2014, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ---------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2014, Tony Rogvall
%%% @doc
%%%    Proxy server session hold the connection to the "user"
%%% @end
%%% Created : 18 Dec 2014 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(xylan_proxy).

-behaviour(gen_server).

%% API
-export([start/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("lager/include/log.hrl").
-include("xylan_socket.hrl").

-record(state, {
	  session_key = <<>> :: binary(),
	  tag_a=tcp, tag_a_closed=tcp_closed, tag_a_error=tcp_error,
	  tag_b=tcp, tag_b_closed=tcp_closed, tag_b_error=tcp_error,
	  parent :: pid(),
	  initial :: binary(),     %% first binary "packet"
	  a_sock :: xylan_socket(),  %% user socket
	  a_closed = false :: boolean(),
	  b_sock :: xylan_socket(),  %% client socket (when connected)
	  b_closed = false :: boolean()
	 }).


%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start(SessionKey) ->
    gen_server:start(?MODULE, [self(), SessionKey], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([Parent, SessionKey]) ->
    {ok, #state{parent=Parent,
		session_key=SessionKey,
		a_sock = undefined,  a_closed = false,
		b_sock = undefined,  b_closed = false
	       }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    ?warning("~s:handle_call: got ~p\n", [_Request]),
    Reply = {error,einval},
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({set_a,Socket}, State) ->
    ?debug("handle_cast: set_a"),
    {T,C,E} = xylan_socket:tags(Socket),
    xylan_socket:setopts(Socket, [{packet,0},{mode,binary},{active,once}]),
    %% FIXME: try route match based only on socket info !
    {noreply, State#state { a_sock = Socket,
			    a_closed = false,
			    tag_a=T, tag_a_closed=C, tag_a_error=E}};
handle_cast({set_b,Socket}, State) ->
    ?debug("handle_cast: set_b, send ~p",[State#state.initial]),
    {T,C,E} = xylan_socket:tags(Socket),
    xylan_socket:setopts(Socket, [{packet,0},{mode,binary},{active,once}]),
    %% reactiveate the a side
    xylan_socket:setopts(State#state.a_sock, [{active,once}]),
    %% this will kick the activity
    xylan_socket:send(Socket, State#state.initial),
    {noreply, State#state { b_sock = Socket,
			    b_closed = false,
			    tag_b=T, tag_b_closed=C, tag_b_error=E}};

handle_cast({connect,LIP,LPort,RIP,RPort}, State) ->
    LOptions = [{mode,binary},{packet,0},{nodelay,true}],
    ?debug("handle_cast: connect: ~p:~w <-> ~p:~w",[LIP,LPort,RIP,RPort]),
    case xylan_socket:connect(LIP,LPort,LOptions,3000) of
	{ok,A} ->
	    ?debug("A is connected"),
	    ROptions = [{mode,binary},{packet,4},{nodelay,true}],
	    case xylan_socket:connect(RIP,RPort,ROptions,3000) of
		{ok,B} ->
		    ?debug("B is connected"),
		    %% FIXME make better and signed!
		    xylan_socket:send(B, State#state.session_key),
		    xylan_socket:setopts(B,[{packet,0},{active,once}]),
		    xylan_socket:setopts(A,[{active,once}]),
		    {Ta,Ca,Ea} = xylan_socket:tags(A),
		    {Tb,Cb,Eb} = xylan_socket:tags(B),
		    State1 = State#state { b_sock = B,
					   b_closed = false,
					   tag_b=Tb, tag_b_closed=Cb, tag_b_error=Eb,
					   a_sock = A,
					   a_closed = false,
					   tag_a=Ta, tag_a_closed=Ca, tag_a_error=Ea},
		    {noreply, State1};
		_Error ->
		    xylan_socket:close(A),
		    ?warning("unable to connect B side to ~p:~p error:~p", 
		     [RIP,RPort,_Error]),
		    {stop, normal, State}
	    end;
	_Error ->
	    ?warning("unable to connect A side to ~p:~p error:~p",
		     [LIP,LPort,_Error]),
	    {stop, normal, State}
    end;

handle_cast(_Msg, State) ->
    ?debug("handle_cast: got ~p\n", [_Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

%% data from A (user) before proxy is connected
handle_info({Tag,Socket,Data}, State) when 
      Tag =:= State#state.tag_a,
      Socket =:= (State#state.a_sock)#xylan_socket.socket ->
    if State#state.b_sock =:= undefined ->
	    {ok,{LocalIP,LocalPort}} = xylan_socket:sockname(State#state.a_sock),
	    {ok,{RemoteIP,RemotePort}} = xylan_socket:peername(State#state.a_sock),
	    RouteInfo = [{dst_ip,inet:ntoa(LocalIP)},{dst_port,LocalPort},
			 {src_ip,inet:ntoa(RemoteIP)},{src_port,RemotePort},
			 {data,Data}],
	    gen_server:cast(State#state.parent, {route,State#state.session_key,RouteInfo}),
	    {noreply, State#state { initial = Data }};
       true ->
	    xylan_socket:send(State#state.b_sock, Data),
	    xylan_socket:setopts(State#state.a_sock, [{active,once}]),
	    {noreply, State}
    end;
%% data from B side proxy
handle_info({Tag,Socket,Data}, State) when 
      Tag =:= State#state.tag_b,
      Socket =:= (State#state.b_sock)#xylan_socket.socket ->
    xylan_socket:send(State#state.a_sock, Data),
    xylan_socket:setopts(State#state.b_sock, [{active,once}]),
    {noreply, State};

%% closed A side (user)
handle_info({Tag,Socket}, State) when
      Tag =:= State#state.tag_a_closed,
      Socket =:= (State#state.a_sock)#xylan_socket.socket ->
    ?debug("got A closed", []),
    if State#state.b_closed;
       State#state.b_sock =:= undefined ->
	    ?debug("both closed", []),
	    %% xylan_socket:close(State#state.user)
	    {stop, normal, State};
       true ->
	    xylan_socket:shutdown(State#state.b_sock, write),
	    %% xylan_socket:close(State#state.user)
	    {noreply, State#state { a_closed = true }}
    end;

handle_info({Tag,Socket}, State) when
      Tag =:= State#state.tag_b_closed,
      Socket =:= (State#state.b_sock)#xylan_socket.socket ->
    ?debug("got B closed", []),
    if State#state.a_closed;
       State#state.a_sock =:= undefined ->
	    ?debug("both closed", []),
	    %% xylan_socket:close(State#state.b_sock)
	    {stop, normal, State};
       true ->
	    xylan_socket:shutdown(State#state.a_sock, write),
	    %% xylan_socket:close(State#state.b_sock)
	    {noreply, State#state { b_closed = true }}
    end;

%% FIXME: add error cases

handle_info(_Info, State) ->
    ?warning("handle_info: got ~p\n", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ?debug("terminate ~p", [_Reason]),
    if State#state.a_sock =/= undefined ->
	    ?debug("terminate close A side (user)"),
	    xylan_socket:close(State#state.a_sock);
       true -> ok
    end,
    if State#state.b_sock =/= undefined ->
	    ?debug("terminate close B side (proxy)"),
	    xylan_socket:close(State#state.b_sock);
       true -> ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
