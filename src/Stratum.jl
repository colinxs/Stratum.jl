module Stratum

import JSON, UUIDs

export StratumEndpoint, send_notification, send_request, send_success_response, send_error_response

include("core.jl")
include("proxy.jl")

end
