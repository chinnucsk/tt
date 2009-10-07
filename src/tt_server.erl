-module(tt_server).
-behaviour(gen_server).

-export([start_link/2]).
-export([init/1]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([terminate/2, code_change/3]).

-record(state, {listener, acceptor, module}).

start_link(Port, Module) -> 
  gen_server:start_link({local, ?MODULE}, ?MODULE, [Port, Module], []).

init([Port, Module]) ->
  process_flag(trap_exit, true),

  %% The socket options will be set on the acceptor socket automatically
  Listen = gen_tcp:listen(Port, [binary, {packet, raw}, {reuseaddr, true},
                          {keepalive, true}, {backlog, 128}, {active, false}]),
  case  Listen of
    {ok, Socket} -> %%Create first accepting process
                    {ok, Ref} = prim_inet:async_accept(Socket, -1),
                    {ok, #state{listener        = Socket,
                                acceptor        = Ref,
                                module          = Module}};
    {error, Reason} -> {stop, Reason}
  end.

handle_call(_Msg, _From, State) -> {noreply, State}.
handle_cast(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

handle_info({inet_async, ListSock, Ref, {ok, CliSocket}}, 
             #state{listener=ListSock, acceptor=Ref, module=Module} = State) ->
  case set_sockopt(ListSock, CliSocket) of
    ok -> {ok, Pid} = erlang:apply(Module, start_link, [CliSocket]),
          gen_tcp:controlling_process(CliSocket, Pid),
          %% Instruct the new FSM that it owns the socket.
          gen_fsm:send_event(Pid, socket_ready),
          {ok, NewRef} = prim_inet:async_accept(ListSock, -1),
          {noreply, State#state{acceptor=NewRef}};
    {error, Reason} -> 
        error_logger:error_msg("Error setting socket options: ~p.\n", [Reason]),
        {stop, Reason, State}
  end;

handle_info({inet_async, ListSock, Ref, Error}, 
            #state{listener=ListSock, acceptor=Ref} = State) ->
  error_logger:error_msg("Error in socket acceptor: ~p.\n", [Error]),
  {stop, exceeded_accept_retry_count, State};

handle_info({'EXIT', Pid, no_socket}, State) ->
  % The back end didn't have any usable sockets left.
  % It cleaned up its connections and there is nothing else to do.
  % Let's log it.
  error_logger:error_msg("Pid ~p ran out of sockets!~n", [Pid]),
  {noreply, State};

handle_info({'EXIT', _Pid, normal}, State) ->
  {noreply, State}.

set_sockopt(ListSock, CliSocket) ->
  true = inet_db:register_socket(CliSocket, inet_tcp),
  case prim_inet:getopts(ListSock, [active, nodelay, 
                                    keepalive, delay_send, priority, tos]) of
    {ok, Opts} -> case prim_inet:setopts(CliSocket, Opts) of
                    ok    -> ok;
                    Error -> gen_tcp:close(CliSocket),
                             Error
                  end;
     Error -> gen_tcp:close(CliSocket), Error
  end.
