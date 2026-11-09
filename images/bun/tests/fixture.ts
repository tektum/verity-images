import { cpSync } from "node:fs";

type Greeting = { runtime: string; version: string; sum: number };

const add = (a: number, b: number): number => a + b;

switch (Bun.argv[2]) {
  case "serve": {
    Bun.serve({
      hostname: "127.0.0.1",
      port: 3000,
      fetch(request: Request): Response {
        if (new URL(request.url).pathname !== "/greet") {
          return new Response("not found", { status: 404 });
        }
        const body: Greeting = { runtime: "bun", version: Bun.version, sum: add(40, 2) };
        return Response.json(body);
      },
    });
    break;
  }
  case "get": {
    const found = await fetch("http://127.0.0.1:3000/greet");
    const body = (await found.json()) as Greeting;
    const missing = await fetch("http://127.0.0.1:3000/missing");
    console.log(`${found.status} ${body.runtime} ${body.version} ${body.sum} ${missing.status}`);
    break;
  }
  case "install": {
    cpSync("/fixture/project", "/app/project", { recursive: true });
    const install = Bun.spawnSync([process.execPath, "install"], { cwd: "/app/project", stderr: "inherit" });
    if (install.exitCode !== 0) process.exit(1);
    const run = Bun.spawnSync([process.execPath, "run", "index.ts"], { cwd: "/app/project", stderr: "inherit" });
    if (run.exitCode !== 0) process.exit(1);
    process.stdout.write(run.stdout);
    break;
  }
  default:
    console.error(`unknown mode: ${Bun.argv[2]}`);
    process.exit(2);
}
