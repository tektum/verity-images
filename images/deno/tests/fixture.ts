const bytes = new TextEncoder().encode("deno");
console.log(bytes.reduce((sum, value) => sum + value, 0));
