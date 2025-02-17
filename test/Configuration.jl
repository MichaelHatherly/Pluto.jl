using HTTP
using Test
using Pluto
using Pluto: ServerSession, ClientSession, SessionActions
using Pluto.Configuration
using Pluto.Configuration: notebook_path_suggestion, from_flat_kwargs, _convert_to_flags
using Pluto.WorkspaceManager: poll

@testset "Configurations" begin

cd(Pluto.project_relative_path("test")) do
    @test notebook_path_suggestion() == joinpath(pwd(), "")
end

@testset "from_flat_kwargs" begin
    opt = from_flat_kwargs(;compile="min", launch_browser=false)
    @test opt.compiler.compile == "min"
    @test opt.server.launch_browser == false

    et = @static if isdefined(Pluto.Configuration.Configurations, :InvalidKeyError)
        Pluto.Configuration.Configurations.InvalidKeyError
    else
        ArgumentError
    end

    @test_throws et from_flat_kwargs(;asdfasdf="test")    
end

@testset "flag conversion" begin
    if VERSION > v"1.5.0-"
        @test _convert_to_flags(Configuration.CompilerOptions(threads="123")) ==
            ["--startup-file=no", "--history-file=no", "--threads=123"]

        @test _convert_to_flags(Configuration.CompilerOptions(threads=123)) ==
            ["--startup-file=no", "--history-file=no", "--threads=123"]

        @test _convert_to_flags(Configuration.CompilerOptions()) ⊇
            ["--startup-file=no", "--history-file=no"]
    else
        @test _convert_to_flags(Configuration.CompilerOptions()) ==
            ["--startup-file=no", "--history-file=no"]
    end
    @test _convert_to_flags(Configuration.CompilerOptions(compile="min")) ⊇
    ["--compile=min", "--startup-file=no", "--history-file=no"]
end

@testset "authentication" begin
    port = 1238
    options = Pluto.Configuration.from_flat_kwargs(; port=port, launch_browser=false, workspace_use_distributed=false)
    🍭 = Pluto.ServerSession(; options=options)
    fakeclient = ClientSession(:fake, nothing)
    🍭.connected_clients[fakeclient.id] = fakeclient
    host = 🍭.options.server.host
    secret = 🍭.secret
    println("Launching test server...")
    server_task = @async Pluto.run(🍭)
    sleep(2)

    local_url(suffix) = "http://$host:$port/$suffix"
    withsecret(url) = occursin('?', url) ? "$url&secret=$secret" : "$url?secret=$secret"
    @test HTTP.get(local_url("favicon.ico")).status == 200

    function requeststatus(url, method)
        r = HTTP.request(method, url; status_exception=false, redirect=false)
        r.status
    end

    nb = SessionActions.open(🍭, Pluto.project_relative_path("sample", "Basic.jl"); as_sample=true)

    simple_routes = [
        ("", "GET"),
        ("edit?id=$(nb.notebook_id)", "GET"),
        ("notebookfile?id=$(nb.notebook_id)", "GET"),
        ("notebookexport?id=$(nb.notebook_id)", "GET"),
        ("statefile?id=$(nb.notebook_id)", "GET"),
    ]

    function tempcopy(x)
        p = tempname()
        Pluto.readwrite(x, p)
        p
    end
    @assert isfile(Pluto.project_relative_path("sample", "Basic.jl"))

    effect_routes = [
        ("new", "GET"),
        ("new", "POST"),
        ("open?url=$(HTTP.URIs.escapeuri("https://raw.githubusercontent.com/fonsp/Pluto.jl/v0.14.5/sample/Basic.jl"))", "GET"),
        ("open?url=$(HTTP.URIs.escapeuri("https://raw.githubusercontent.com/fonsp/Pluto.jl/v0.14.5/sample/Basic.jl"))", "POST"),
        ("open?path=$(HTTP.URIs.escapeuri(Pluto.project_relative_path("sample", "Basic.jl") |> tempcopy))", "GET"),
        ("open?path=$(HTTP.URIs.escapeuri(Pluto.project_relative_path("sample", "Basic.jl") |> tempcopy))", "POST"),
        ("sample/Basic.jl", "GET"),
        ("sample/Basic.jl", "POST"),
        ("notebookupload", "POST"),
    ]

    for (suffix, method) in simple_routes ∪ effect_routes
        url = local_url(suffix)
        @test requeststatus(url, method) == 403
    end

    # no notebooks were opened
    @test length(🍭.notebooks) == 1

    for (suffix, method) in simple_routes
        url = local_url(suffix) |> withsecret
        @test requeststatus(url, method)  ∈ 200:299
    end

    for (suffix, method) in setdiff(effect_routes, [("notebookupload", "POST")])
        url = local_url(suffix) |> withsecret
        @test requeststatus(url, method) ∈ 200:399 # 3xx are redirects
    end

    @async schedule(server_task, InterruptException(); error=true)
end

@testset "Open Notebooks at Startup" begin
    port = 1338
    host = "localhost"
    local_url(suffix) = "http://$host:$port/$suffix"

    urls = [
    "https://raw.githubusercontent.com/fonsp/Pluto.jl/v0.12.16/sample/Basic.jl",
    "https://gist.githubusercontent.com/fonsp/4e164a262a60fc4bdd638e124e629d64/raw/8ffe93c680e539056068456a62dea7bf6b8eb622/basic_pkg_notebook.jl",
    ]
    nbnames = download.(urls)

    # without notebook at startup
    server_task = @async Pluto.run(port=port, launch_browser=false, workspace_use_distributed=false, require_secret_for_access=false)
    @test poll(5) do
        HTTP.get(local_url("favicon.ico")).status == 200
    end
    @async schedule(server_task, InterruptException(); error=true)

    # with a single notebook at startup
    server_task = @async Pluto.run(notebook=first(nbnames), port=port, launch_browser=false, workspace_use_distributed=false, require_secret_for_access=false)
    @test poll(5) do
        HTTP.get(local_url("favicon.ico")).status == 200
    end
    @async schedule(server_task, InterruptException(); error=true)

    # with multiple notebooks at startup
    server_task = @async Pluto.run(notebook=nbnames, port=port, launch_browser=false, workspace_use_distributed=false, require_secret_for_access=false)
    @test poll(5) do
        HTTP.get(local_url("favicon.ico")).status == 200
    end
    @async schedule(server_task, InterruptException(); error=true)

end

end # testset
