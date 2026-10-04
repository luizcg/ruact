// Simulates three server-side changes on ruact's real payloads:
// 1. import rows as [id, chunks, name] (React's webpack shape)
// 2. a text row referenced as "$<hex>" (React's "$T" means a temporary reference)
// 3. Suspense: a symbol row "$Sreact.suspense" as the type, and the deferred
//    content as a lazy child "$L<id>" instead of an element whose type is $L.
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
for (const f of readdirSync("payloads/ruact")) {
  let w = readFileSync(`payloads/ruact/${f}`, "utf8");
  w = w.replace(/^(\h*|[0-9a-f]+):I\["([^"]+)","([^"]+)",(\[[^\]]*\])\]$/gm, (_, id, mod, name, chunks) => `${id}:I["${mod}",${chunks},"${name}"]`);
  w = w.replace(/"\$T([0-9a-f]+)"/g, '"$$$1"');
  if (w.includes('"$SS"')) {
    w = w.replace('"$SS"', '"$ff"').replace(/"children":\["\$","\$L([0-9a-f]+)",null,\{\}\]/, '"children":"$$L$1"');
    w = `ff:"$Sreact.suspense"\n` + w;
  }
  writeFileSync(`payloads/ruact-fixed/${f}`, w);
}
