# included in client_server_test.jl
using WebSockets
import Random.randstring

"""
`servercoroutine`is called by the listen loop (`starserver`) for each accepted http request.
A near identical server coroutine is implemented as an inner function in WebSockets.serve.
The 'function arguments' `server_gatekeeper` and `httphandler` are defined below.
"""
function servercoroutine(stream::WebSockets.Stream)
    @debug "We received a request"
    if WebSockets.is_upgrade(stream.message)
        @debug "...which is an upgrade"
        WebSockets.upgrade(server_gatekeeper, stream)
    else
        @debug "...which is not an upgrade"
        WebSockets.Servers.handle_request(httphandler,
                                        stream)
    end
end

"""
`httphandler` is called by `servercoroutine` for all accepted http requests
that are not upgrades. We don't check what's actually requested.
"""
httphandler(req::WebSockets.Request) = WebSockets.Response(200, "OK")

"""
`server_gatekeeper` is called by `servercouroutine` or WebSockets inner function
`_servercoroutine` for all http requests that
    1) qualify as an upgrade,
    2) request a subprotocol we claim to support
Based on the requested subprotocol, server_gatekeeper calls
    `initiatingws`
        or
    `echows`
"""
function server_gatekeeper(req::WebSockets.Request, ws::WebSocket)
    @debug "server_gatekeeper"
    origin(req) != "" && @error "server_gatekeeper, got origin header as from a browser."
    target(req) != "/" && @error "server_gatekeeper, got origin header as in a POST request."
    if subprotocol(req) == "Server start the conversation"
        initiatingws(ws, 10, false)
    else
        echows(ws)
    end
    @debug "exiting server_gatekeeper"
end



"""
`echows` is called by
    - `server_gatekeeper` (in which case ws will be a server side websocket)
    or
    - 'WebSockets.open' (in which case ws will be a client side websocket)

Takes an open websocket.
Reads a message, echoes it, closes by exiting.
The tests will be captured if the function is run on client side.
If started by the server side, this is called as part of a coroutine.
Therefore, test results will not propagate to the enclosing test scope.
"""
function echows(ws::WebSocket)
    @debug "echows ", ws
    data, ok = readguarded(ws)
    if ok
        if writeguarded(ws, data)
            @test true
        else
            @test false
            @error "echows, couldn't write data ", ws
        end
    else
        @test false
        @error "echows, couldn't read ", ws
    end
end

"""
`initiatingws` is called by
    - `server_gatekeeper` (in which case ws will be a server side websocket)
    or
    - 'WebSockets.open' (in which case ws will be a client side websocket)

Takes
    - an open websocket
    keyword arguments
    - msglengths = a vector of message lengths, defaults to MSGLENGTHS
    - closebeforeexit, defaults to false

1) Pings, but does not check for received pong. There will be console output from the pong side.
2) Send a message of specified length
3) Checks for an exact echo
4) Repeats 2-4 until no more message lenghts are specified.
"""
function initiatingws(ws::WebSocket; msglengths = MSGLENGTHS, closebeforeexit = false)
    @debug "initiatews ", ws
    @debug "String lengths $msglengths bytes"
    send_ping(ws)
    # No ping check made, the above will just output some info message.

    # We need to yield since we are sharing the same process as the task on the
    # other side of the connection.
    # The other side must be reading in order to process the ping-pong.
    yield()
    for slen in msglengths
        test_str = randstring(slen)
        forcecopy_str = test_str |> collect |> copy |> join
        if writeguarded(ws, test_str)
            yield()
            readback, ok = readguarded(ws)
            if ok
                # if run by the server side, this test won't be captured.
                if String(readback) == forcecopy_str
                    @test true
                else
                    if ws.server == true
                        @error "initatews, echoed string of length ", slen, " differs from sent "
                    else
                        @test false
                    end
                end
            else
                # if run by the server side, this test won't be captured.
                if ws.server == true
                    @error "initatews, couldn't read ", ws, " length sent is ", slen
                else
                    @test false
                end
            end
            closebeforeexit && close(ws, statusnumber = 1000)
        else
            @test false
            @error "initatews, couldn't write to ", ws, " length ", slen
        end
    end
    @debug "initiatews exiting"
end

closeserver(ref::Ref{WebSockets.TCPServer}) = close(ref[])
closeserver(ref::WebSockets.ServerWS) =  put!(ref.in, "Any message means close!")


"""
`startserver` is called from tests.
Keyword argument
    - usinglisten   defines which syntax to use internally. The resulting server
     task should act identical with the exception of catching some errors.

Returns
    1) a task where a server is running
    2) a reference which can be used for closing the server or checking trapped errors.
        The type of reference depends on argument usinglisten.
For usinglisten = true, error messages can sometimes be inspected through opening
a web server.
For usinglisten = false, error messages can sometimes be inspected through take!(reference.out)

To close the server, call
    closeserver(reference)
"""
function startserver(;surl = SURL, port = PORT, usinglisten = false)
    if usinglisten
        reference = Ref{WebSockets.TCPServer}()
        servertask = @async WebSockets.HTTP.listen(servercoroutine,
                                            SURL,
                                            PORT,
                                            tcpref = reference,
                                            tcpisvalid = checkratelimit,
                                            ratelimits = Dict{IPAddr, WebSockets.RateLimit}()
                                            )
        while !istaskstarted(servertask);yield();end
    else
        @debug "Here we are, in startserver."
        @debug typeof(server_gatekeeper)
        reference =  WebSockets.ServerWS(   WebSockets.HTTP.Handlers.HandlerFunction(httphandler),
                                            WebSockets.WebsocketHandler(server_gatekeeper)
                                        )
        servertask = @async WebSockets.serve(reference, SURL, PORT)
        while !istaskstarted(servertask);yield();end
        if isready(reference.out)
            # capture errors, if any were made during the definition.
            @error take!(myserver_WS.out)
        end
    end
    servertask, reference
end

"""
`startclient` is called from tests. TODO consider replacing.
"""
function startclient((servername, wsuri), stringlength, closebeforeexit)
    # the external websocket test server does not follow our interpretation of
    # RFC 6455 the protocol for length zero messages. Skip such tests.
    stringlength == 0 && occursin("echo.websocket.org", wsuri) && return
    @info("Testing client -> server at $(wsuri), message length $len")
    test_str = randstring(len)
    forcecopy_str = test_str |> collect |> copy |> join
    @debug TCPREF[]
    WebSockets.open(wsuri)
end
true