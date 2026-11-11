using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;

var app = WebApplication.CreateBuilder(args).Build();
app.MapGet("/", () => "hello from verity aspnet");
app.MapGet("/urls", (IConfiguration config) => config["URLS"] ?? config["ASPNETCORE_URLS"] ?? "unset");
app.MapGet("/json", () => Results.Json(new { framework = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription }));
app.Run();
