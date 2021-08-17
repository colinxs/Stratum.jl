struct StratumError <: Exception
    code::Int
    msg::AbstractString
    data::Any
end

function Base.showerror(io::IO, ex::StratumError)
    error_code_as_string = if ex.code == -32700
        "ParseError"
    elseif ex.code == -32600
        "InvalidRequest"
    elseif ex.code == -32601
        "MethodNotFound"
    elseif ex.code == -32602
        "InvalidParams"
    elseif ex.code == -32603
        "InternalError"
    elseif ex.code == -32099
        "serverErrorStart"
    elseif ex.code == -32000
        "serverErrorEnd"
    elseif ex.code == -32002
        "ServerNotInitialized"
    elseif ex.code == -32001
        "UnknownErrorCode"
    elseif ex.code == -32800
        "RequestCancelled"
	elseif ex.code == -32801
        "ContentModified"
    else
        "Unkonwn"
    end

    print(io, error_code_as_string)
    print(io, ": ")
    print(io, ex.msg)
    if ex.data !== nothing
        print(io, " (")
        print(io, ex.data)
        print(io, ")")
    end
end

mutable struct StratumEndpoint{IOIn <: IO,IOOut <: IO}
    pipe_in::IOIn
    pipe_out::IOOut

    out_msg_queue::Channel{Any}
    in_msg_queue::Channel{Any}

    outstanding_requests::Dict{String,Channel{Any}}

    name::Union{Nothing,String}

    err_handler::Union{Nothing,Function}

    status::Symbol

    read_task::Union{Nothing,Task}
    write_task::Union{Nothing,Task}
end

StratumEndpoint(pipe_in, pipe_out, name = nothing, err_handler = nothing) =
    StratumEndpoint(pipe_in, pipe_out, Channel{Any}(Inf), Channel{Any}(Inf), Dict{String,Channel{Any}}(), name, err_handler, :idle, nothing, nothing)

function write_transport_layer(stream, response)
    @info "write_transport_layer" response
    response_utf8 = transcode(UInt8, response)
    write(stream, response_utf8, '\n')
    flush(stream)
end

function read_transport_layer(stream)
    msg = chomp(readline(stream))
    @info "read_transport_layer" msg
    return msg
end

Base.isopen(x::StratumEndpoint) = x.status != :closed && isopen(x.pipe_in) && isopen(x.pipe_out)

function Base.run(x::StratumEndpoint)
    x.status == :idle || error("Endpoint is not idle.")

    x.write_task = @async try
        try
            for msg in x.out_msg_queue
                if isopen(x.pipe_out)
                    @info "Sent message $(x.name):" msg 
                    write_transport_layer(x.pipe_out, msg)
                else
                    # TODO Reconsider at some point whether this should be treated as an error.
                    break
                end
            end
        finally
            @info "CLOSE"
            close(x.out_msg_queue)
        end
    catch err
        bt = catch_backtrace()
        if x.err_handler !== nothing
            x.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end

    x.read_task = @async try
        try
            while true
                message = read_transport_layer(x.pipe_in)

                if message === nothing || x.status == :closed
                    break
                end

                # @info "Received message $(x.name):" message
                message_dict = JSON.parse(message)
                id = get(message_dict, "id", nothing)
                if haskey(x.outstanding_requests, id)
                    channel_for_response = x.outstanding_requests[id]
                    put!(channel_for_response, message_dict)
                    delete!(channel_for_response, id)
                else
                    try
                        put!(x.in_msg_queue, message_dict)
                    catch err
                        if err isa InvalidStateException
                            break
                        else
                            rethrow(err)
                        end
                    end
                end
            end
        finally
            close(x.in_msg_queue)
        end
    catch err
        bt = catch_backtrace()
        if x.err_handler !== nothing
            x.err_handler(err, bt)
        else
            Base.display_error(stderr, err, bt)
        end
    end

    x.status = :running
end

function send_notification(x::StratumEndpoint, method::AbstractString, params)
    check_dead_endpoint!(x)

    message = Dict("jsonrpc" => "2.0", "method" => method, "params" => params)

    message_json = JSON.json(message)

    put!(x.out_msg_queue, message_json)

    return nothing
end

function send_request(x::StratumEndpoint, method::AbstractString, params)
    check_dead_endpoint!(x)

    id = string(UUIDs.uuid4())
    message = Dict("jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id)

    response_channel = Channel{Any}(1)
    x.outstanding_requests[id] = response_channel

    message_json = JSON.json(message)

    put!(x.out_msg_queue, message_json)

    response = take!(response_channel)

    if haskey(response, "result")
        return response["result"]
    elseif haskey(response, "error")
        error_code = response["error"]["code"]
        error_msg = response["error"]["message"]
        error_data = get(response["error"], "data", nothing)
        throw(StratumError(error_code, error_msg, error_data))
    else
        throw(StratumError(0, "ERROR AT THE TRANSPORT LEVEL", nothing))
    end
end

function get_next_message(endpoint::StratumEndpoint)
    check_dead_endpoint!(endpoint)

    msg = take!(endpoint.in_msg_queue)

    return msg
end

function put_message!(endpoint::StratumEndpoint, msg)
    check_dead_endpoint!(endpoint)

    put!(endpoint.out_msg_queue, JSON.json(msg))

    return endpoint 
end

function Base.iterate(endpoint::StratumEndpoint, state = nothing)
    check_dead_endpoint!(endpoint)

    try
        return take!(endpoint.in_msg_queue), nothing
    catch err
        if err isa InvalidStateException
            return nothing
        else
            rethrow(err)
        end
    end
end

function send_success_response(endpoint, original_request, result)
    check_dead_endpoint!(endpoint)

    response = Dict("jsonrpc" => "2.0", "id" => original_request["id"], "result" => result)

    response_json = JSON.json(response)

    put!(endpoint.out_msg_queue, response_json)
end

function send_error_response(endpoint, original_request, code, message, data)
    check_dead_endpoint!(endpoint)

    response = Dict("jsonrpc" => "2.0", "id" => original_request["id"], "error" => Dict("code" => code, "message" => message, "data" => data))

    response_json = JSON.json(response)

    put!(endpoint.out_msg_queue, response_json)
end

function Base.close(endpoint::StratumEndpoint)
    flush(endpoint)

    endpoint.status = :closed
    isopen(endpoint.in_msg_queue) && close(endpoint.in_msg_queue)
    isopen(endpoint.out_msg_queue) && close(endpoint.out_msg_queue)

    fetch(endpoint.write_task)
    # TODO we would also like to close the read Task
    # But unclear how to do that without also closing
    # the socket, which we don't want to do
    # fetch(endpoint.read_task)
end

function Base.flush(endpoint::StratumEndpoint)
    check_dead_endpoint!(endpoint)

    while isready(endpoint.out_msg_queue)
        yield()
    end
end

function check_dead_endpoint!(endpoint)
    status = endpoint.status
    status === :running && return
    error("Endpoint is not running, the current state is $(status).")
end


struct StratumProxy
    from::StratumEndpoint
    to::StratumEndpoint
    
    err_handler::Union{Nothing,Function}
    
    msg_queue::Channel{Any}

    status::Symbol

    task::Union{Nothing,Task}
end
StratumProxy(from, to, err_handler = nothing) = StratumProxy(from, to, err_handler, Channel{Any}(Inf), :idle, nothing)


function Base.run(x::StratumProxy)
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
