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
%%%    Proxy wedding server, accept "clients" proxies to register a session
%%%    to act as the real servers. Users connect and rules determine where
%%%    the connection will be sent.
%%% @end
%%% Created : 18 Dec 2014 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(xylan_srv).

-behaviour(gen_server).

%% API
-export([start_link/0, start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(DEFAULT_CNTL_PORT, 29390).   %% client proxy control port
-define(DEFAULT_DATA_PORT, 29391).   %% client proxy data port
-define(DEFAULT_PORT, 46122).        %% user connect port
-define(DEFAULT_AUTH_TIMEOUT, 5000). %% timeout for authentication packet
-define(DEFAULT_DATA_TIMEOUT, 5000). %% timeout for proxy data connection

-include_lib("lager/include/log.hrl").
-include_lib("exo/src/exo_socket.hrl").


-type interface() :: atom() | string().
-type timer() :: reference().

-type user_port() :: 
	inet:port_numer() |
	{inet:ip_address(), inet:port_numer()} |
	{interface(), inet:port_numer()}.

-type user_ports() :: 
	user_port() | [user_port()].

-type regexp() :: iodata().

-type route_config() :: 
	{data, regexp()} |
	{ip, inet:ip_address()|regexp()} |
	{port, integer()}.

-record(client,
	{
	  id :: string(),          %% name of client
	  server_key :: binary(),   %% server side key
	  client_key :: binary(),   %% client side key
	  pid :: pid(),             %% client process
	  mon :: reference(),       %% monitor of above
	  route :: [[route_config()]]  %% config
	}).
	  
-record(state,
	{
	  server_id :: string(),
	  %% fixme: may need to be able to have multiple control sockets
	  cntl_sock :: exo_socket:exo_socket(),  %% control chan listen socket
	  cntl_port :: integer(),
	  cntl_ref  :: term(), %% async accept reference
	  data_sock :: exo_socket:exo_socket(),  %% data chan listen socket
	  data_port :: integer(),
	  data_ref  :: term(), %% async accept reference
	  user_socks :: [{exo_socket:exo_socket(), term()}], %% listen sockets
	  user_ports :: user_ports(),
	  clients = []  :: [#client{}],
	  auth_list = [] :: [{exo_socket:exo_socket(),timer()}], %% client sesion
	  data_list = [] :: [{exo_socket:exo_socket(),timer()}], %% client data proxy
	  proxy_list = [] :: [{pid(),reference(),binary()}],     %% proxy sessions
	  auth_timeout  = ?DEFAULT_AUTH_TIMEOUT :: timeout(),
	  data_timeout  = ?DEFAULT_DATA_TIMEOUT :: timeout()
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
start_link() ->
    start_link([]).

start_link(Options) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Options, []).

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
init(Options) ->
    CntlPort = proplists:get_value(client_port,Options,?DEFAULT_CNTL_PORT),
    DataPort = proplists:get_value(data_port,Options,?DEFAULT_DATA_PORT),
    UserPorts = proplists:get_value(port,Options,?DEFAULT_PORT),
    ServerID = proplists:get_value(id,Options,""),
    AuthTimeout = proplists:get_value(auth_timeout,Options,?DEFAULT_AUTH_TIMEOUT),
    Clients = [begin 
		   SKey=xylan_lib:make_key(proplists:get_value(server_key,ClientConf)),
		   CKey=xylan_lib:make_key(proplists:get_value(client_key,ClientConf)),
		   Route = proplists:get_value(route, ClientConf),
		   {ok,CPid} = xylan_session:start(AuthTimeout),
		   CMon = erlang:monitor(process, CPid),
		   gen_server:cast(CPid,
				   {set_config, [{client_id,ClientID},
						 {server_id,ServerID},
						 {server_key,SKey},
						 {client_key,CKey}]}),
		   #client {
		      id = ClientID,
		      server_key = SKey,
		      client_key = CKey,
		      pid = CPid,
		      mon = CMon,
		      route = Route}
	       end || {ClientID,ClientConf} <- proplists:get_value(clients, Options, [])],
    {ok,CntlSock} = start_client_cntl(CntlPort),
    {ok,DataSock} = start_client_data(DataPort),
    UserSocks = start_user(UserPorts),
    {ok,CntlRef} = exo_socket:async_accept(CntlSock),
    {ok,DataRef} = exo_socket:async_accept(DataSock),
    AuthTimeout = proplists:get_value(auth_timeout,Options,?DEFAULT_AUTH_TIMEOUT),
    DataTimeout = proplists:get_value(data_timeout,Options,?DEFAULT_DATA_TIMEOUT),
    {ok, #state{ server_id = ServerID,
		 cntl_sock=CntlSock, cntl_port = CntlPort, cntl_ref=CntlRef,
		 data_sock=DataSock, data_port = DataPort, data_ref=DataRef,
		 user_socks=UserSocks, user_ports = UserPorts,
		 clients = Clients,
		 auth_timeout = AuthTimeout,
		 data_timeout = DataTimeout
	       }}.


start_client_cntl(Port) ->
    exo_socket:listen(Port, [tcp], [{reuseaddr,true},
				    {nodelay, true},
				    {mode,binary},
				    {packet,4}]).

start_client_data(Port) ->
    exo_socket:listen(Port, [tcp], [{reuseaddr,true},
				    {nodelay, true},
				    {mode,binary},
				    {packet,4}]).

start_user(Ports) when is_list(Ports) ->
    lists:foldl(
      fun(Port,Acc) when is_integer(Port) ->
	      open_user_port(Port,any) ++ Acc;
	 ({IP,Port},Acc) when is_tuple(IP), is_integer(Port) ->
	      open_user_port(Port,IP) ++ Acc;
	 ({Name,Port},Acc) when is_list(Name), is_integer(Port) ->
	      case xylan_lib:lookup_ip(Name,inet) of
		  {error,_} ->
		      ?warning("No such interface ~p",[Name]),
		      Acc;
		  {ok,IP} ->
		      open_user_port(Port,IP) ++ Acc
	      end
      end, [], Ports);
start_user(Port) ->
    start_user([Port]).

open_user_port(Port,IP) when is_integer(Port) ->
    case exo_socket:listen(Port, [tcp], [{reuseaddr,true},
					 {nodelay, true},
					 {mode,binary},
					 {ifaddr,IP},
					 {packet,0}]) of
	{ok,Socket} ->
	    {ok,Ref} = exo_socket:async_accept(Socket),
	    [{Socket,Ref}];
	Error ->
	    ?warning("Error listen to port ~w:~p ~p",[Port,IP,Error]),
	    []
    end.

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
    Reply = ok,
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

handle_cast(Msg={route,SessionKey,RouteInfo}, State) ->
    %% user session got some data, try to route to a client
    %% by some rule, current rule is to take first client
    %% fixme: verify user ?  yes!
    ?debug("got route : ~p", [Msg]),
    case route_cs(State#state.clients, RouteInfo) of
	false ->
	    ?warning("failed to route ~p", [RouteInfo]),
	    {noreply, State};
	{ok,Client} when is_pid(Client#client.pid) ->
	    gen_server:cast(Client#client.pid,
			    {route,State#state.data_port,SessionKey,RouteInfo}),
	    {noreply, State};
	{ok,Client} ->
	    ?warning("client ~s not connected",[Client#client.id]),
	    {noreply, State}
    end;
handle_cast(_Msg, State) ->
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


%% accept Incoming user socket
handle_info({inet_async, Listen, Ref, {ok,Socket}} = _Msg, State) ->
    if
	Listen =:= (State#state.cntl_sock)#exo_socket.socket, Ref =:= State#state.cntl_ref ->
	    ?debug("handle_info: (client control) ~p", [_Msg]),
	    {ok,Ref1} = exo_socket:async_accept(State#state.cntl_sock),
	    AuthOpts = [],  %% [delay_auth]
	    case exo_socket:async_socket(State#state.cntl_sock, Socket, AuthOpts) of
		{ok, XSocket} ->
		    exo_socket:setopts(XSocket, [{active,once}]),
		    Timeout = State#state.auth_timeout,
		    TRef=erlang:start_timer(Timeout,self(),auth_timeout),
		    Ls = [{XSocket,TRef}|State#state.auth_list],
		    {noreply, State#state { auth_list=Ls, cntl_ref = Ref1 }};
		_Error ->
		    ?error("inet_accept: ~p", [_Error]),
		    {noreply, State#state { cntl_ref=Ref1}}
	    end;
	Listen =:= (State#state.data_sock)#exo_socket.socket, Ref =:= State#state.data_ref ->
	    ?debug("handle_info: (client data) ~p", [_Msg]),
	    {ok,Ref1} = exo_socket:async_accept(State#state.data_sock),
	    AuthOpts = [],  %% [delay_auth]
	    case exo_socket:async_socket(State#state.data_sock, Socket, AuthOpts) of
		{ok, XSocket} ->
		    %% FIXME: add options that allow some ports to be SERVER INITIATE ports!!!
		    %% wait for first packet should contain the correct SessionKey!
		    exo_socket:setopts(XSocket, [{active,once}]),
		    Timeout = State#state.data_timeout,
		    TRef=erlang:start_timer(Timeout,self(),data_timeout),
		    Ls = [{XSocket,TRef}|State#state.data_list],
		    {noreply, State#state { data_list = Ls, data_ref=Ref1}};
		_Error ->
		    ?error("handle_info: ~p", [_Error]),
		    {noreply, State#state { data_ref=Ref1}}
	    end;
	true ->
	    ?debug("handle_info: (user connect) ~p", [_Msg]),
	    case lists:keytake(Ref, 2, State#state.user_socks) of
		false ->
		    ?error("handle_info: listen socket not found"),
		    {noreply, State};
		{value,{UserSock,Ref},UserSocks} ->
		    {ok,Ref1} = exo_socket:async_accept(UserSock),
		    UsersSocks1 = [{UserSock,Ref1}|UserSocks],
		    AuthOpts = [],  %% [delay_auth]
		    SessionKey = crypto:rand_bytes(16),
		    case exo_socket:async_socket(UserSock,Socket,AuthOpts) of
			{ok, XSocket} ->
			    case xylan_proxy:start(SessionKey) of
				{ok, Pid} ->
				    Mon = erlang:monitor(process, Pid),
				    exo_socket:controlling_process(XSocket, Pid),
				    gen_server:cast(Pid, {set_a,XSocket}),
				    Ls = [{Pid,Mon,SessionKey}|State#state.proxy_list],
				    {noreply, State#state { proxy_list = Ls,
							    user_socks=UsersSocks1}};
				_Error ->
				    ?error("inet_accept: (user) ~p", [_Error]),
				    exo_socket:close(XSocket),
				    {noreply, State#state { user_socks=UsersSocks1}}
			    end;
			_Error ->
			    ?error("inet_accept: (user) ~p", [_Error]),
			    {noreply, State#state { user_socks=UsersSocks1}}
		    end
	    end
    end;

%% client data message
handle_info(_Info={Tag,Socket,Data}, State) when
      (Tag =:= tcp orelse Tag =:= ssl) ->
    ?debug("handle_info: (data channel) ~p", [_Info]),
    case take_socket(Socket, 1, State#state.data_list) of
	false ->
	    case take_socket(Socket, 1, State#state.auth_list) of
		false ->
		    ?warning("handle_info: socket not found, data=~p",[Data]),
		    {noreply, State};
		{value,{XSocket,TRef},AuthList} ->
		    %% session socket data received
		    cancel_timer(TRef),
		    try binary_to_term(Data, [safe]) of
			Message = {auth_req,[{id,ID},{chal,_Chal}]} ->
			    case lists:keyfind(ID, #client.id, State#state.clients) of
				false ->
				    ?warning("client not found, ~p",[Message]),
				    exo_socket:close(XSocket),
				    {noreply, State#state { auth_list = AuthList }};
				Client when is_pid(Client#client.pid) ->
				    ?debug("client req=~p",[Message]),
				    exo_socket:controlling_process(XSocket, Client#client.pid),
				    gen_server:cast(Client#client.pid, {set_socket, XSocket}),
				    gen_server:cast(Client#client.pid, Message),
				    {noreply, State#state { auth_list = AuthList }};
				_Client ->
				    ?debug("client not connected, ~p",[Message]),
				    exo_socket:close(XSocket),
				    {noreply, State#state { auth_list = AuthList }}
			    end;
			Other ->
			    ?warning("handle_info: bad client message=~p",[Other]),
			    exo_socket:close(XSocket),
			    {noreply, State#state { auth_list = AuthList }}
		    catch
			error:Reason ->
			    ?warning("handle_info: bad client message=~p",[{error,Reason}]),
			    exo_socket:close(XSocket),
			    {noreply, State#state { auth_list = AuthList }}
		    end
	    end;

	{value,{XSocket,TRef},Ls} ->
	    cancel_timer(TRef),
	    %% data packet <<SessionKey:16>>
	    case lists:keytake(Data,3,State#state.proxy_list) of
		false ->
		    ?warning("handle_info: no user found id=~p",[Data]),
	    	    {noreply, State};
		{value,{Proxy,Mon,_Data},ProxyList} ->
		    erlang:demonitor(Mon, [flush]),
		    exo_socket:controlling_process(XSocket, Proxy),
		    gen_server:cast(Proxy, {set_b,XSocket}),
		    {noreply, State#state { proxy_list = ProxyList,data_list=Ls }}
	    end
    end;

%% client data socket closed before proxy connection is established
handle_info(_Info={Tag,Socket}, State) when
      (Tag =:= tcp_closed orelse Tag =:= ssl_closed) ->
    ?debug("handle_info: (data channel) ~p", [_Info]),
    {noreply, close_socket(Socket, State)};

%% data socket got error before proxy established
handle_info(_Info={Tag,Socket,_Error}, State) when 
      (Tag =:= tcp_error orelse Tag =:= ssl_error) ->
    ?debug("handle_info: (data channel) ~p", [_Info]),
    {noreply, close_socket(Socket, State)};

handle_info({timeout,TRef,auth_timeout}, State) ->
    case lists:keytake(TRef,2,State#state.auth_list) of
	false ->
	    ?debug("auth_timeout already removed"),
	    {noreply, State};
	{value,{Socket,TRef},Ls} ->
	    ?info("auth_timeout"),
	    exo_socket:close(Socket),
	    {noreply, State#state { auth_list = Ls}}
    end;

handle_info({timeout,TRef,data_timeout}, State) ->
    case lists:keytake(TRef,2,State#state.data_list) of
	false ->
	    ?debug("data_timeout already removed"),
	    {noreply, State};
	{value,{Socket,TRef},Ls} ->
	    ?info("data_timeout"),
	    exo_socket:close(Socket),
	    {noreply, State#state { data_list = Ls}}
    end;

handle_info(_Info={'DOWN',Ref,process,_Pid,_Reason}, State) ->
    ?debug("handle_info: got: ~p\n", [_Info]),
    case lists:keytake(Ref, 2, State#state.proxy_list) of
	{value,_Proxy,Ls} ->
	    ?debug("proxy stopped ~p\n", [_Reason]),
	    {noreply, State#state { proxy_list = Ls}};
	false ->
	    case lists:keytake(Ref, #client.mon, State#state.clients) of
		false ->
		    {noreply, State};
		{value,C,Clients} ->
		    ?debug("client stopped ~p restart client ~s", [_Reason,C#client.id]),
		    {ok,ClientPid} = xylan_session:start(State#state.auth_timeout),
		    ClientMon = erlang:monitor(process, ClientPid),
		    Clients1 = [C#client { pid = ClientPid,
					   mon = ClientMon } | Clients],
		    {noreply, State#state { clients = Clients1 }}
	    end
    end;
handle_info(_Info, State) ->
    ?warning("handle_info: got: ~p\n", [_Info]),
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
terminate(_Reason, _State) ->
    ok.

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

cancel_timer(undefined) -> false;
cancel_timer(Timer) -> erlang:cancel_timer(Timer).

close_socket(Socket, State) ->
    %% remove socket from auth_list or data_lsit and close it
    case take_socket(Socket,1,State#state.data_list) of
	false ->
	    case take_socket(Socket,1,State#state.auth_list) of
		false ->
		    State;
		{value,{Socket,TRef},Ls} ->
		    ?debug("close client socket"),
		    cancel_timer(TRef),
		    exo_socket:close(Socket),
		    State#state { auth_list = Ls }
	    end;
	{value,{Socket,TRef},Ls} ->
	    ?debug("close data socket"),
	    cancel_timer(TRef),
	    exo_socket:close(Socket),
	    State#state { data_list = Ls }
    end.

take_socket(Socket,Pos,SocketList) when is_integer(Pos), Pos >= 0 ->
    take(fun (#exo_socket { socket=S }) -> S=:=Socket end, Pos, SocketList).

take(Fun, Pos, List) when is_function(Fun), is_list(List) ->
    take_(Fun, Pos, List, []).

take_(Fun, Pos, [H|T], Acc) ->
    Elem = if Pos =:= 0 -> H; true -> element(Pos,H) end,
    case Fun(Elem) of
	true ->
	    {value,H,lists:reverse(Acc)++T};
	false ->
	    take_(Fun,Pos,T,[H|Acc])
    end;
take_(_Fun, _Pos, [], _Acc) ->
    false.


route_cs([Client|Cs], RouteInfo) ->
    case match_route(Client#client.route, RouteInfo) of
	true -> {ok,Client};
	false -> route_cs(Cs, RouteInfo)
    end;
route_cs([], _RouteInfo) ->
    false.

match_route([R|Rs], RouteInfo) ->
    case match(R, RouteInfo) of
	true  -> true;
	false -> match_route(Rs, RouteInfo)
    end;
match_route([], _RouteInfo) ->
    false.

match([{data,RE}|R], RouteInfo) ->
    case proplists:get_value(data, RouteInfo) of
	undefined -> false;
	Data -> match_data(Data, RE, R, RouteInfo)
    end;
match([{dst_ip,RE}|R], RouteInfo) ->
    case proplists:get_value(dst_ip, RouteInfo) of
	undefined -> false;
	IP when is_tuple(IP) -> match_data(inet:ntoa(IP), RE, R, RouteInfo);
	IP when is_list(IP) ->  match_data(IP, RE, R, RouteInfo);
	_ -> false
    end;
match([{dst_port,RE}|R], RouteInfo) ->
    case proplists:get_value(dst_port, RouteInfo) of
	undefined -> false;
	RE -> true;
	Port when is_integer(Port) ->
	    match_data(integer_to_list(Port), RE, R, RouteInfo);
	Port when is_list(Port) ->  match_data(Port, RE, R, RouteInfo);
	_ -> false
    end;
match([{src_ip,RE}|R], RouteInfo) ->
    case proplists:get_value(src_ip, RouteInfo) of
	undefined -> false;
	IP when is_tuple(IP) -> match_data(inet:ntoa(IP), RE, R, RouteInfo);
	IP when is_list(IP) ->  match_data(IP, RE, R, RouteInfo);
	_ -> false
    end;
match([{src_port,RE}|R], RouteInfo) ->
    case proplists:get_value(src_port, RouteInfo) of
	undefined -> false;
	RE -> true;
	Port when is_integer(Port) ->
	    match_data(integer_to_list(Port), RE, R, RouteInfo);
	Port when is_list(Port) ->  match_data(Port, RE, R, RouteInfo);
	_ -> false
    end;
match([M|_R], _RouteInfo) ->
    ?warning("unknown route match ~p", [M]),
    false;
match([], _RouteInfo) ->
    true.

match_data(String, RE, R, RouteInfo) when is_integer(RE) -> 
    match_data(String, integer_to_list(RE), R, RouteInfo);	     
match_data(String, RE, R, RouteInfo) ->	
    case re:run(String,RE) of
	{match,_} -> match(R, RouteInfo);
	nomatch -> false
    end.
	    