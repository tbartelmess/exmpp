%% Copyright ProcessOne 2006-2010. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.

%% @author Mickael Remond <mickael.remond@process-one.net>

%% @doc
%% The module <strong>{@module}</strong> manages XMPP over HTTP connection
%% according to the BOSH protocol (XEP-0124: Bidirectional-streams Over
%% Synchronous HTTP)
%%
%% <p>
%% This module is not intended to be used directly by client developers.
%% </p>
%%
%% This module uses HTTP parsing functions based on the lhttpc library.
%% http://bitbucket.org/etc/lhttpc/wiki/Home
%% http://bitbucket.org/etc/lhttpc/src/tip/LICENCE

-module(exmpp_bosh).

%-include_lib("exmpp/include/exmpp.hrl").
-include("exmpp.hrl").

%% Behaviour exmpp_gen_transport ?
-export([
    connect/3,
    send/2, close/2,
    reset_parser/1,
    get_property/2,
    wping/1
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).


-define(CONTENT_TYPE, "text/xml; charset=utf-8").
-define(VERSION, "1.8").
-define(WAIT, 120). %1 minute
-define(HOLD, 1). %only 1 request pending

-define(CONNECT_TIMEOUT, 20 * 1000).

-record(state,
{
  parsed_bosh_url, % {Host::string(), Port:integer(), Path::string(), Ssl::bool()}
  domain          = "",
  sid             = <<>>,
  rid             = 0,
  auth_id         = <<>>,
  client_pid,
  stream_ref,
  max_requests,  %TODO: use this, now fixed on 2
  queue,         %% stanzas that have been queued because we reach the limit of requets
  new             = true,
  open,          % [{Rid, Socket}]
  free,          %[socket()] free keep-alive connections
  local_ip,      %ip to bind sockets to
  local_port
}).

% Valid PropValues: rid | sid
% get_property(_, rid) -> integer()
% get_property(_, sid) -> binary()
get_property(Pid, Prop) when Prop == rid ; Prop == sid ->
    {ok, gen_server:call(Pid, {get_property, Prop})};
get_property(_Pid, _Prop) ->
    {error, undefined}.

reset_parser(Pid) ->
    gen_server:call(Pid,reset_parser, infinity).

connect(ClientPid, StreamRef, {URL, Domain, Options}) ->
    {ok, Pid} = gen_server:start_link(?MODULE,
        [ClientPid, StreamRef, URL, Domain, Options], []),
    {Pid, Pid}.

send(Pid, Packet) ->
    gen_server:cast(Pid, {send, Packet}).

close(Pid, _) ->
    catch gen_server:call(Pid, stop).

%% Don't send whitespace pings on BOSH
wping(_Pid) ->
    ok.

%% don't do anything on init. We establish the connection when the stream start 
%% is sent
init([ClientPid, StreamRef, URL, Domain, Options]) ->
    {A,B,C} = now(),
    random:seed(A,B,C),
%    Rid = 1000 + random:uniform(100000),
%    ParsedUrl = parse_url(URL),
%    IP = proplists:get_value(local_ip, Options, undefined),
%    Port= proplists:get_value(local_port, Options, undefined),
    State = #state{
        parsed_bosh_url = parse_url(URL),
        domain = Domain,
        rid = 1000 + random:uniform(100000),
        open = 0,
        client_pid = ClientPid,
        queue = [],
        free = [],
        local_ip = proplists:get_value(local_ip, Options, undefined),
        local_port = proplists:get_value(local_port, Options, undefined),
        stream_ref = exmpp_xmlstream:set_wrapper_tagnames(StreamRef, [<<"body">>])
    },
    {ok, State}.

handle_call({get_property, rid}, _From, State) ->
    {reply, State#state.rid, State};
handle_call({get_property, sid}, _From, State) ->
    {reply, State#state.sid, State};

%% reset the connection. We send here a fake stream response to the client to.
%% TODO: check if it is not best to do this in do_send/2
handle_call(reset_parser, _From,
  #state{parsed_bosh_url = {Host, _Port, Path ,_}} = State) ->
    {NewState, Socket} = new_socket(State, once),
    ok = make_raw_request(Socket, Host, Path,
        restart_stream_msg(State#state.sid, State#state.rid, State#state.domain)),
    StreamStart = [
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client'"
        " xmlns:stream='http://etherx.jabber.org/streams' version='1.0'"
        " from='" , State#state.domain , "' id='" , State#state.auth_id , "'>"
    ],
    NewStreamRef = exmpp_xmlstream:reset(State#state.stream_ref),
    {ok, NewStreamRef2} = exmpp_xmlstream:parse(NewStreamRef, StreamStart),
    {reply,
     ok,
     NewState#state{
         new = false,
         rid = State#state.rid + 1,
         open = [{Socket, State#state.rid}|State#state.open],
         stream_ref = NewStreamRef2
     },
     hibernate};



handle_call(stop, _From, State = #state{parsed_bosh_url = {Host, _Port, Path ,_}}) ->
    {NewState, Socket} = new_socket(State, false),
    ok = make_raw_request(Socket, Host, Path,
        close_stream_msg(State#state.sid, State#state.rid)),
    {stop, normal, ok, NewState};
handle_call(_Call, _From, State) ->
    {reply, ok, State}.

handle_cast({send, Packet}, State) ->
    do_send(Packet, State);
handle_cast(_Cast, State) ->
    {noreply, State}.
%{http_response, NewVsn, StatusCode, Reason}
handle_info({http, Socket, {http_response, Vsn, 200, <<"OK">>}},
  #state{parsed_bosh_url = {Host, _, Path, _}} = State) ->
    {ok, {{200, <<"OK">>}, _Hdrs, Resp}} =
        read_response(Socket, Vsn, {200, <<"OK">>}, [], <<>>),
    {ok, NewStream} = exmpp_xmlstream:parse(State#state.stream_ref, Resp),
    %io:format("Got: ~s \n", [Resp]),
    NewOpen = lists:keydelete(Socket, 1, State#state.open),
    NewState2  = if
        NewOpen == [] andalso State#state.new =:= false ->
            %io:format("Making empty request\n"),
            ok = make_empty_request(Socket, State#state.sid, State#state.rid,
                State#state.queue, Host, Path),
            inet:setopts(Socket, [{packet, http_bin}, {active, once}]),
            State#state{
                open = [{Socket, State#state.rid}],
                rid = State#state.rid +1,
                queue = []
            };
        true ->
            %io:format("Closing the socket\n"),
            NewState = return_socket(State, Socket),
            NewState#state{open = NewOpen}
        end, 
        {noreply, NewState2#state{stream_ref = NewStream}, hibernate};

handle_info({tcp_closed, Socket}, State) ->
    case lists:keymember(Socket, 1, State#state.open) of
        true ->
            {stop, {error, tcp_closed}, State};
        false ->
            {noreply, State#state{free = lists:delete(Socket, State#state.free)}}
    end;

handle_info(_Info, State) ->
    error_logger:error_report([{unknown_info_in_bosh, _Info}]),
    {stop, _Info, State}.
terminate(_Reason, #state{open = Open}) when is_list(Open) ->
    lists:map(fun({Socket, _}) -> gen_tcp:close(Socket) end, Open),
    ok;
terminate(_Reason, #state{}) ->
    ok.
code_change(_Old, State, _Extra) ->
    {ok, State}.


make_empty_request(Socket, Sid, Rid, Queue, Host, Path) ->
    StanzasText = [exxml:doc_to_iolist(I) || I <- lists:reverse(Queue)],
    Body = stanzas_msg(Sid, Rid, StanzasText),
    make_request(Socket, Host, Path, Body).

make_raw_request(Socket, Host, Path, Body) ->
    make_request(Socket, Host, Path, Body).  

make_request(Socket, Sid, Rid, Queue, Host, Path, Packet) when is_record(Packet, xmlel) ->
    StanzasText = [exxml:doc_to_iolist(I) || I <- lists:reverse([Packet|Queue])],
    Body = stanzas_msg(Sid, Rid, StanzasText),
    make_request(Socket, Host, Path, Body).

make_request(Socket,Host, Path, Body) ->
    Hdrs = [{"Content-Type", ?CONTENT_TYPE}, {"keep-alive", "true"}],
    Request = format_request(Path, "POST", Hdrs, Host, Body),
    ok = gen_tcp:send(Socket, Request).
    %io:format("Sent: ~s \n", [Body]).


%% after stream restart, we must not sent this to the connection manager. The response is got in reset call
do_send(#xmlel{name = Name}, #state{new = false} = State) 
  when Name == <<"stream">> ; Name == <<"stream:stream">>->
    {noreply, State};
% we start the session with the connection manager here.
do_send(#xmlel{name = Name}, State) 
  when Name == <<"stream">> ; Name == <<"stream:stream">>->
    #state{parsed_bosh_url = ParsedURL} = State,
    {Host, _Port, Path, _Ssl} = ParsedURL,
    {NewState, Socket} = new_socket(State, false),
    ok = make_raw_request(Socket, Host, Path,
        create_session_msg(State#state.rid, State#state.domain, ?WAIT, ?HOLD)),
    {ok, {{200, <<"OK">>}, _Hdrs, Resp}} =
        read_response(Socket, nil, nil, [], <<>>),
    NewState2 = return_socket(NewState, Socket),
    %%TODO: this can be improved.. don't close the socket and reuse it for latter
    {ok, [#xmlel{name = <<"body">>} = Xmlel_Body]} = exxml:parse_document(Resp),
    SID = exxml:get_attr(Xmlel_Body, <<"sid">>, undefined),
    AuthID = exxml:get_attr(Xmlel_Body, <<"authid">>, undefined),
    Requests = list_to_integer(binary_to_list(
        exxml:get_attr(Xmlel_Body, <<"requests">>, undefined))),
    Events = [{xmlstreamelement, Xmlel} || Xmlel <- exxml:get_els(Xmlel_Body)],
    % first return a fake stream response, then anything found inside the <body/>
    % element (possibly nothing)
    StreamStart = [
        "<?xml version='1.0'?><stream:stream xmlns='jabber:client'"
        " xmlns:stream='http://etherx.jabber.org/streams' version='1.0'"
        " from='" , State#state.domain , "' id='" , AuthID , "'>"
    ],
    {ok, NewStreamRef} = exmpp_xmlstream:parse(State#state.stream_ref, StreamStart),
    exmpp_xmlstream:send_events(State#state.stream_ref, Events),
    {noreply,
     NewState2#state{
         stream_ref = NewStreamRef,
         rid = State#state.rid + 1,
         open = [],
         sid = SID,
         max_requests = Requests,
         auth_id = AuthID}
    };

do_send(Packet, #state{parsed_bosh_url = {Host, _Port, Path, _}} = State) ->
    Result = if
        State#state.open == [] ->
            send;
        true ->
            Min = lists:min(lists:map(fun({_S,R}) -> R end, State#state.open)),
            if
                (State#state.rid - Min) =< 1 ->
                    send;
                true ->
                    queue
            end
    end,
    case Result of
        send ->
            {NewState, Socket} = new_socket(State, once),
            ok = make_request(Socket, State#state.sid, State#state.rid,
                State#state.queue, Host, Path, Packet), 
            {noreply,
             NewState#state{
                 rid = State#state.rid + 1,
                 open = [{Socket, State#state.rid} | State#state.open]
             },
             hibernate};
        queue -> 
            %io:format("Queuing request.    Open = ~p    Rid= ~p \n", [Open, Rid]),
            Queue = State#state.queue,
            NewQueue =  [Packet|Queue], 
            {noreply, State#state{queue = NewQueue}} 
    end.


 %%TODO  a veces tiene que ser activo, otras veces pasivo. 
new_socket(State = #state{free = [Socket | Rest]}, Active) ->
    inet:setopts(Socket, [{active, Active}, {packet, http_bin}]),
    {State#state{free = Rest}, Socket};
new_socket(State = #state{parsed_bosh_url = {Host, Port, _, _}, local_port = LocalPort},
  Active) ->
    Options = case State#state.local_ip of
        undefined ->
            [{active, Active}, {packet, http_bin}];
        _ ->
            case LocalPort of
                undefined ->
                    [{active, Active},
                     {packet, http_bin},
                     {ip, State#state.local_ip}];
                _ ->
                    [{active, Active},
                     {packet, http_bin},
                     {ip, State#state.local_ip},
                     {port, LocalPort()}]
            end
    end,
    {ok, Socket} = gen_tcp:connect(Host, Port,  Options, ?CONNECT_TIMEOUT),
    {State, Socket}.

return_socket(State, Socket) ->
    inet:setopts(Socket, [{active, once}]),
    %receive data from it, we want to know if something happens
    State#state{free = [Socket | State#state.free]}.

%new_socket(Host, Port, Active) ->
%    {ok, Socket} = gen_tcp:connect(Host, Port, [{active, Active}, {packet, http_bin}], ?CONNECT_TIMEOUT),
% Socket 

create_session_msg(Rid, To, Wait, Hold) ->
    [ "<body xmlns='http://jabber.org/protocol/httpbind'"
      " content='text/xml; charset=utf-8'",
      " ver='1.8'"
      " to='", To, "'",
      " rid='", integer_to_list(Rid), "'"
      " xmlns:xmpp='urn:xmpp:xbosh'",
      " xmpp:version='1.0'",
      " wait='", integer_to_list(Wait), "'"
      " hold='", integer_to_list(Hold), "'/>"].

stanzas_msg(Sid, Rid, Text) ->
    [ "<body xmlns='http://jabber.org/protocol/httpbind' "
      " rid='", integer_to_list(Rid), "'"
      " sid='", Sid, "'>", Text, "</body>"].

restart_stream_msg(Sid, Rid, Domain) ->
    [ "<body xmlns='http://jabber.org/protocol/httpbind' "
      " rid='", integer_to_list(Rid), "'",
      " sid='", Sid, "'",
      " xmpp:restart='true'",
      " xmlns:xmpp='urn:xmpp:xbosh'",
      " to='", Domain, "'",
      "/>"].

close_stream_msg(Sid, Rid) ->
    [ "<body xmlns='http://jabber.org/protocol/httpbind' "
      " rid='", integer_to_list(Rid), "'",
      " sid='", Sid, "'",
      " type='terminate'",
      " xmlns:xmpp='urn:xmpp:xbosh'",
      "/>"].




%receiver(Socket, BoshProcess) ->
%        inet:setopts(Socket, [{packet, http_bin}, {active, false}]),
%       {ok, Resp} = read_response(Socket, nil, nil, [], <<>>),      
%       BoshProcess ! {http_response, Resp},                         
%       receiver(Socket, BoshProcess).                               



read_response(Socket, Vsn, Status, Hdrs, Body) ->
    inet:setopts(Socket, [{packet, http_bin}, {active, false}]),
    case gen_tcp:recv(Socket, 0) of
        {ok, {http_response, NewVsn, StatusCode, Reason}} ->
            NewStatus = {StatusCode, Reason},
            read_response(Socket, NewVsn, NewStatus, Hdrs, Body);
        {ok, {http_header, _, Name, _, Value}} ->
            Header = {Name, Value},
            read_response(Socket, Vsn, Status, [Header | Hdrs], Body);
        {ok, http_eoh} ->
            inet:setopts(Socket, [{packet, raw}, binary]),
            {NewBody, NewHdrs} = read_body(Vsn, Hdrs, Socket),
            Response = {Status, NewHdrs, NewBody},
            {ok, Response};
        {error, closed} ->
            erlang:error(closed);
        {error, Reason} ->
            erlang:error(Reason)
    end.

read_body(_Vsn, Hdrs, Socket) ->
    % Find out how to read the entity body from the request.
    % * If we have a Content-Length, just use that and read the complete
    %   entity.
    % * If Transfer-Encoding is set to chunked, we should read one chunk at
    %   the time 
    % * If neither of this is true, we need to read until the socket is
    %   closed (AFAIK, this was common in versions before 1.1)
    case proplists:get_value('Content-Length', Hdrs, undefined) of
        undefined ->
            throw({no_content_length, Hdrs});
        ContentLength ->
            read_length(Hdrs, Socket, list_to_integer(binary_to_list(ContentLength)))
    end.

read_length(Hdrs, Socket, Length) ->
    case gen_tcp:recv(Socket, Length) of
        {ok, Data} ->
            {Data, Hdrs};
        {error, Reason} ->
            erlang:error(Reason)
    end.
%% @spec (URL) -> {Host, Port, Path, Ssl}
%%   URL = string()
%%   Host = string()
%%   Port = integer()
%%   Path = string()
%%   Ssl = bool()
%% @doc
-spec parse_url(string()) -> {string(), integer(), string(), boolean()}.
parse_url(URL) ->
    % XXX This should be possible to do with the re module?
    {Scheme, HostPortPath} = split_scheme(URL),
    {Host, PortPath} = split_host(HostPortPath, []),
    {Port, Path} = split_port(Scheme, PortPath, []),
    {string:to_lower(Host), Port, Path, Scheme =:= https}.

split_scheme("http://" ++ HostPortPath) ->
    {http, HostPortPath};
split_scheme("https://" ++ HostPortPath) ->
    {https, HostPortPath}.

split_host([$: | PortPath], Host) ->
    {lists:reverse(Host), PortPath};
split_host([$/ | _] = PortPath, Host) ->
    {lists:reverse(Host), PortPath};
split_host([H | T], Host) ->
    split_host(T, [H | Host]);
split_host([], Host) -> 
    {lists:reverse(Host), []}.

split_port(http, [$/ | _] = Path, []) ->
    {80, Path};
split_port(https, [$/ | _] = Path, []) ->
    {443, Path};
split_port(http, [], []) ->
    {80, "/"};
split_port(https, [], []) ->
    {443, "/"};
split_port(_, [], Port) ->
    {list_to_integer(lists:reverse(Port)), "/"};
split_port(_,[$/ | _] = Path, Port) ->
    {list_to_integer(lists:reverse(Port)), Path};
split_port(Scheme, [P | T], Port) ->
    split_port(Scheme, T, [P | Port]).

%% @spec (Path, Method, Headers, Host, Body) -> Request
%% Path = iolist()
%% Method = atom() | string()
%% Headers = [{atom() | string(), string()}]
%% Host = string()
%% Body = iolist()
format_request(Path, Method, Hdrs, Host, Body) ->
    [
        Method, " ", Path, " HTTP/1.1\r\n",
        format_hdrs(add_mandatory_hdrs(Method, Hdrs, Host, Body), []),
        Body
    ].

%% spec normalize_method(AtomOrString) -> Method
%%   AtomOrString = atom() | string()
%%   Method = string()
%% doc
%% Turns the method in to a string suitable for inclusion in a HTTP request
%% line.
%% end
%-spec normalize_method(atom() | string()) -> string().
%normalize_method(Method) when is_atom(Method) ->
%    string:to_upper(atom_to_list(Method));
%normalize_method(Method) ->
%    Method.

format_hdrs([{Hdr, Value} | T], Acc) ->
    NewAcc = [Hdr, ":", Value, "\r\n" | Acc],
    format_hdrs(T, NewAcc);
format_hdrs([], Acc) ->
    [Acc, "\r\n"].

add_mandatory_hdrs(Method, Hdrs, Host, Body) ->
    add_host(add_content_length(Method, Hdrs, Body), Host).

add_content_length("POST", Hdrs, Body) ->
    add_content_length(Hdrs, Body);
add_content_length("PUT", Hdrs, Body) ->
    add_content_length(Hdrs, Body);
add_content_length(_, Hdrs, _) ->
    Hdrs.

add_content_length(Hdrs, Body) ->
    case proplists:get_value("content-length", Hdrs, undefined) of
        undefined ->
            ContentLength = integer_to_list(iolist_size(Body)),
            [{"Content-Length", ContentLength} | Hdrs];
        _ -> % We have a content length
            Hdrs
    end.

add_host(Hdrs, Host) ->
    case proplists:get_value("host", Hdrs, undefined) of
        undefined ->
            [{"Host", Host } | Hdrs];
        _ -> % We have a host
            Hdrs
    end.


