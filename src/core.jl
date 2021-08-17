abstract type AbstractMessageType <: AbstractDict{AbstractString,Any} end
const MessageType = Dict{String,Any}

struct StratumError <: Exception
    code::Int
    msg::AbstractString
    data::Any
end

function Base.showerror(io::IO, ex::StratumError)
    error_code_as_string =
    # JSON RPC 2.0 Error Codes
    # https://www.jsonrpc.org/specification#error_object
        if ex.code == -32700
            "ParseError"
        elseif ex.code == -32600
            "InvalidRequest"
        elseif ex.code == -32601
            "MethodNotFound"
        elseif ex.code == -32602
            "InvalidParams"
        elseif ex.code == -32603
            "InternalError"

            # Stratum V1 Error Codes
            # https://braiins.com/stratum-v1/docs
        elseif ex.code == 20
            "Unknown"
        elseif ex.code == 21
            "JobNotFound"
        elseif ex.code == 22
            "DuplicateShare"
        elseif ex.code == 23
            "LowDifficultyShare"
        elseif ex.code == 24
            "UnauthorizedWorker"
        elseif ex.code == 25
            "NotSubscribed"

        else
            "Unknown"
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

mutable struct StratumEndpoint{IOIn<:IO,IOOut<:IO,MsgIn<:MessageType,MsgOut<:MessageType}
    pipe_in::IOIn
    pipe_out::IOOut

    name::Union{Nothing,String}

    err_handler::Union{Nothing,Function}

    msg_queue_in::Channel{MsgIn}
    msg_queue_out::Channel{MsgOut}

    outstanding_requests::Dict{String,Channel{MessageType}}

    status::Symbol

    reader::Union{Nothing,Task}
    writer::Union{Nothing,Task}
end

function StratumEndpoint(pipe_in, pipe_out; name=nothing, err_handler=nothing)
    return StratumEndpoint(
        pipe_in,
        pipe_out,
        name,
        err_handler,
        Channel{MessageType}(Inf),
        Channel{MessageType}(Inf),
        Dict{String,Channel{MessageType}}(),
        :idle,
        nothing,
        nothing,
    )
end


Base.isopen(x::StratumEndpoint) = x.status === :running && iswritable(x) && isreadable(x) 

function check_isopen(x::StratumEndpoint)
    isopen(x) || error("Endpoint is not open") 
    return nothing
end

Base.iswritable(x::StratumEndpoint) = isopen(x.msg_queue_out) && isopen(x.pipe_out)
Base.isreadable(x::StratumEndpoint) = isopen(x.msg_queue_in)  && isopen(x.pipe_in)

check_writable(x::StratumEndpoint) = iswritable(x) || error("Endpoint is not writable")
check_readable(x::StratumEndpoint) = isreadable(x) || error("Endpoint is not readable")

function Base.take!(x::StratumEndpoint)
    check_isopen(x)
    msg = take!(x.msg_queue_in)
    return msg
end

function Base.put!(x::StratumEndpoint, msg::AbstractDict)
    check_isopen(x)
    put!(x.msg_queue_out, msg) 
    return x 
end

function write_transport_layer(x::StratumEndpoint, msg::AbstractString)
    msg_utf8 = transcode(UInt8, msg)
    n = write(x.pipe_out, msg_utf8, '\n')
    flush(x.pipe_out)
    return n
end

function read_transport_layer(x::StratumEndpoint) 
    msg = chomp(readline(x.pipe_in))
    return msg
end


function Base.run(x::StratumEndpoint)
    x.status == :idle   || error("Endpoint is not idle.")
    x.status == :closed && error("Endpoint is closed.")

    x.status = :running

    x.writer = @async try
        try
            while true
                msg = take!(x.msg_queue_out)
                isopen(x) || break
                write_transport_layer(x, JSON.json(msg))
                x.name === nothing ? (@debug "Sent:" msg) : (@debug "Sent ($(x.name)):" msg)
            end
        finally
            x.name === nothing ? (@debug "Closed") : (@debug "Closed ($(x.name)):")
            close(x.msg_queue_out)
            close(x.pipe_out)
        end
    catch err
        bt = catch_backtrace()
        handle_error(x, err, bt)
    end

    x.reader = @async try
        try
            while true
                msg_raw = read_transport_layer(x) 
                (isopen(x) && !isempty(msg_raw)) || break

                msg = JSON.parse(msg_raw)
                x.name === nothing ? (@debug "Received:" msg) : (@debug "Received ($(x.name)):" msg)

                id = get(msg, "id", nothing)
                if haskey(x.outstanding_requests, id)
                    put!(x.outstanding_requests[id], msg)
                else
                    put!(x.msg_queue_in, msg)
                end
            end
        finally
            x.name === nothing ? (@debug "Closed") : (@debug "Closed ($(x.name)):")
            close(x.msg_queue_in)
            close(x.pipe_in)
        end
    catch err
        bt = catch_backtrace()
        handle_error(x, err, bt)
    end

    return x
end

function handle_error(x::StratumEndpoint, err, bt)
    if x.err_handler !== nothing
        x.err_handler(err, bt)
    else
        Base.display_error(stderr, err, bt)
    end
end


function send_notification(x::StratumEndpoint, method::AbstractString, params)
    check_isopen(x)

    msg = Dict("jsonrpc" => "2.0", "method" => method, "params" => params)

    put!(x, msg)

    return nothing
end

function send_request(x::StratumEndpoint, method::AbstractString, params)
    check_isopen(x)

    id = string(UUIDs.uuid4())
    msg = Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)

    x.outstanding_requests[id] = Channel{MessageType}(1)

    put!(x, msg)

    response = take!(x.outstanding_requests[id])
    delete!(x.outstanding_requests, id)

    if haskey(response, "result")
        # TODO which makes the most sense?
        # return response["result"]
        return response
    elseif haskey(response, "error")
        err_code, err_msg, err_data = response["error"]
        throw(StratumError(err_code, err_msg, err_data))
    else
        throw(StratumError(0, "ERROR AT THE TRANSPORT LEVEL", nothing))
    end
end

function Base.iterate(x::StratumEndpoint, state=nothing)
    check_isopen(x)
    try
        return take!(x), nothing
    catch err
        if err isa InvalidStateException
            return nothing
        else
            rethrow(err)
        end
    end
end

function send_success_response(x, original_request, result)
    msg = Dict("jsonrpc" => "2.0", "id" => original_request["id"], "result" => result)
    return put!(x, msg)
end

function send_error_response(x, original_request, err_code, err_msg, err_data)
    msg = Dict(
        "jsonrpc" => "2.0",
        "id" => original_request["id"],
        "error" => [err_code, err_msg, err_data],
    )
    return put!(x, msg)
end

function Base.close(x::StratumEndpoint)
    flush(x)

    x.status = :closed

    close(x.msg_queue_in)
    close(x.msg_queue_out)

    close(x.pipe_in)
    close(x.pipe_out)

    fetch(x.writer)
    fetch(x.reader)

    return nothing
end

function Base.flush(x::StratumEndpoint)
    check_isopen(x)

    while isready(x.msg_queue_out)
        yield()
    end
end

