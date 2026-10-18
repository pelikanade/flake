#!/usr/bin/env node
import { readFileSync, writeFileSync } from "node:fs"

const [, , templatePath, outputPath, hostProtocolVersion, nodeVersion] = process.argv
if (templatePath === undefined || outputPath === undefined
  || hostProtocolVersion === undefined || nodeVersion === undefined) {
  console.error("usage: desktop-runtime-json.mjs <template> <output> <hostProtocolVersion> <nodeVersion>")
  process.exit(2)
}

const version = Number(hostProtocolVersion)
if (!Number.isInteger(version) || version < 1) {
  console.error(`desktop runtime descriptor: invalid host protocol version ${hostProtocolVersion}`)
  process.exit(1)
}
if (!/^[0-9][0-9A-Za-z.+-]*$/u.test(nodeVersion)) {
  console.error(`desktop runtime descriptor: invalid node version ${nodeVersion}`)
  process.exit(1)
}

const descriptor = JSON.parse(readFileSync(templatePath, "utf8"))
if (typeof descriptor?.release !== "object" || descriptor.release === null) {
  console.error("desktop runtime descriptor: the template has no release object")
  process.exit(1)
}

descriptor.release.hostProtocolVersion = version
descriptor.release.nodeVersion = nodeVersion
writeFileSync(outputPath, JSON.stringify(descriptor))
