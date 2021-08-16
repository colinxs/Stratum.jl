@testset "Message dispatcher" begin

    if Sys.iswindows()
        global_socket_name1 = "\\\\.\\pipe\\jsonrpc-testrun1"
    elseif Sys.isunix()
        global_socket_name1 = joinpath(tempdir(), "jsonrpc-testrun1")
    else
        error("Unknown operating system.")
    end

    request1_type = Stratum.RequestType("request1", Foo, String)
    request2_type = Stratum.RequestType("request2", Nothing, String)
    notify1_type = Stratum.NotificationType("notify1", String)

    global g_var = ""

    server_is_up = Base.Condition()

    server_task = @async try
        server = listen(global_socket_name1)
        notify(server_is_up)
        sock = accept(server)
        global conn = Stratum.StratumEndpoint(sock, sock)
        global msg_dispatcher = Stratum.MsgDispatcher()

        msg_dispatcher[request1_type] = (conn, params) -> begin
            @test Stratum.is_currently_handling_msg(msg_dispatcher)
            params.fieldA == 1 ? "YES" : "NO"
        end
        msg_dispatcher[request2_type] = (conn, params) -> Stratum.StratumError(-32600, "Our message", nothing)
        msg_dispatcher[notify1_type] = (conn, params) -> g_var = params

        run(conn)

        for msg in conn
            Stratum.dispatch_msg(conn, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name1)
    conn2 = StratumEndpoint(sock2, sock2)

    run(conn2)

    Stratum.send(conn2, notify1_type, "TEST")

    res = Stratum.send(conn2, request1_type, Foo(fieldA=1, fieldB="FOO"))

    @test res == "YES"
    @test g_var == "TEST"

    @test_throws Stratum.StratumError(-32600, "Our message", nothing) Stratum.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task)

    # Now we test a faulty server

    if Sys.iswindows()
        global_socket_name2 = "\\\\.\\pipe\\jsonrpc-testrun2"
    elseif Sys.isunix()
        global_socket_name2 = joinpath(tempdir(), "jsonrpc-testrun2")
    else
        error("Unknown operating system.")
    end

    server_is_up = Base.Condition()

    server_task2 = @async try
        server = listen(global_socket_name2)
        notify(server_is_up)
        sock = accept(server)
        global conn = Stratum.StratumEndpoint(sock, sock)
        global msg_dispatcher = Stratum.MsgDispatcher()

        msg_dispatcher[request2_type] = (conn, params)->34 # The request type requires a `String` return, so this tests whether we get an error.

        run(conn)

        for msg in conn
            @test_throws ErrorException("The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.") Stratum.dispatch_msg(conn, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name2)
    conn2 = StratumEndpoint(sock2, sock2)

    run(conn2)

    @test_throws Stratum.StratumError(-32603, "The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.", nothing) Stratum.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task)

end
