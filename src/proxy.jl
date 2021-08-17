struct StratumProxyServer
    left::StratumEndpoint
    right::StratumEndpoint
    
    err_handler::Union{Nothing,Function}
    
    left_msg_queue::Channel{Any}
    right_msg_queue::Channel{Any}

    status::Symbol

    left_task::Union{Nothing,Task}
    right_task::Union{Nothing,Task}
end
StratumProxyServer(left, right, err_handler = nothing) = StratumProxyServer(left, right, err_handler, Channel{Any}(Inf), Channel{Any}(Inf), :idle, nothing, nothing)

function Base.run(x::StratumProxyServer)
    x.status == :idle || error("Proxy is not idle.")
    x.task = @async try
        try
            while true
                msg = get_next_message(x.from)
                put!(x.msg_queue, msg)
                put_message!(x.to, msg)
            end
        finally
            close(x.msg_queue)
        end
    catch err
        bt = catch_backtrace()
        if x.err_handler !== nothing
            x.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end
end

function proxy(proxy::StratumProxyServer, from::StratumEndpoint, from_msg_queue::Channel, to::StratumEndpoint)
    try
        while true
            msg = get_next_message(from)
            # put!(from_msg_queue, 
            # put_message!(to, msg) 
        end
    catch err
        # TODO handle InvalidStateException?
        bt = catch_backtrace()
        if proxy.err_handler !== nothing
            proxy.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end
end

