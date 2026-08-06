const mode = Deno.args[0] ?? "fixture";

if (mode === "read") {
  await Deno.readTextFile("/etc/os-release");
} else if (mode === "net") {
  await fetch("https://example.com");
} else if (mode === "identity") {
  if (Deno.uid() !== 65532 || Deno.gid() !== 65532) Deno.exit(1);
} else {
  if (!Deno.version.deno.startsWith("2.")) Deno.exit(1);
  const bytes = new TextEncoder().encode("deno");
  console.log(bytes.reduce((sum, value) => sum + value, 0));
}
