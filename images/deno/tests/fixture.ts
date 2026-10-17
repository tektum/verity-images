const mode = Deno.args[0] ?? "fixture";

if (mode === "read") {
  await Deno.readTextFile("/etc/os-release");
} else if (mode === "net") {
  await fetch("https://example.com");
} else if (mode === "directories") {
  for (const path of ["/app", "/deno-dir"]) {
    const info = await Deno.stat(path);
    if (!info.isDirectory || info.uid !== 65532 || info.gid !== 65532 || info.mode === null || (info.mode & 0o777) !== 0o755) Deno.exit(1);
  }
} else if (mode === "identity") {
  if (Deno.uid() !== 65532 || Deno.gid() !== 65532) Deno.exit(1);
} else if (mode === "dns") {
  // Serve two canned answers from an in-process UDP name server, so the
  // runtime's DNS resolver is exercised without any external network.
  const port = 5300;
  const server = Deno.listenDatagram({ hostname: "127.0.0.1", port, transport: "udp" });
  (async () => {
    for await (const [query, addr] of server) {
      let end = 12;
      while (query[end] !== 0) end += query[end] + 1;
      end += 5;
      const question = query.slice(12, end);
      const missing = (question[1] | 0x20) === 0x6d;
      const answer = missing ? [] : [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 53];
      await server.send(new Uint8Array([query[0], query[1], 0x81, missing ? 0x83 : 0x80, 0, 1, 0, missing ? 0 : 1, 0, 0, 0, 0, ...question, ...answer]), addr);
    }
  })();
  const nameServer = { ipAddr: "127.0.0.1", port };
  const found = await Deno.resolveDns("verity.test", "A", { nameServer });
  if (found.length !== 1 || found[0] !== "192.0.2.53") Deno.exit(1);
  try {
    await Deno.resolveDns("missing.test", "A", { nameServer });
    Deno.exit(1);
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) Deno.exit(1);
  }
  server.close();
} else {
  if (!Deno.version.deno.startsWith("2.")) Deno.exit(1);
  const bytes = new TextEncoder().encode("deno");
  console.log(bytes.reduce((sum, value) => sum + value, 0));
}
