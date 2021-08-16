@testset "Core" begin
    @test sprint(showerror, Stratum.StratumError(-32700, "FOO", "BAR")) == "ParseError: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32600, "FOO", "BAR")) == "InvalidRequest: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32601, "FOO", "BAR")) == "MethodNotFound: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32602, "FOO", "BAR")) == "InvalidParams: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32603, "FOO", "BAR")) == "InternalError: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32099, "FOO", "BAR")) == "serverErrorStart: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32000, "FOO", "BAR")) == "serverErrorEnd: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32002, "FOO", "BAR")) == "ServerNotInitialized: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32001, "FOO", "BAR")) == "UnknownErrorCode: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32800, "FOO", "BAR")) == "RequestCancelled: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(-32801, "FOO", "BAR")) == "ContentModified: FOO (BAR)"
    @test sprint(showerror, Stratum.StratumError(1, "FOO", "BAR")) == "Unkonwn: FOO (BAR)"
end
