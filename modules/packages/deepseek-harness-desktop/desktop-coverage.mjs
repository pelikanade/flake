#!/usr/bin/env node
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs"
import { isBuiltin } from "node:module"
import { join, relative } from "node:path"

const SPECIFIER = /(?:from|require|import)\s*\(?\s*["\x27]([^"\x27]+)["\x27]/gu

const OPTIONAL = new Set(["node-addon-require-builtin"])

function providedByRuntime(specifier) {
  return specifier === "electron" || specifier.startsWith("electron/")
}

function packageName(specifier) {
  const parts = specifier.split("/")
  return specifier.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0]
}

// Upstream's electron-builder `files` list ships lib/main.js, the worker and
// preloads, lib/welcome, renderer and package.json -- never lib/types. That
// directory holds the compiled type-checker output, which the bundled main.js
// inlines, so a bare import it names neither loads nor has to resolve here.
const UNSHIPPED = ["lib/types"]

function shippedSources(root) {
  const files = []
  const unshipped = new Set(UNSHIPPED.map(sub => join(root, sub)))
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name)
      if (unshipped.has(path)) continue
      if (entry.isDirectory()) visit(path)
      else if (/\.(?:c|m)?js$/u.test(entry.name)) files.push(path)
    }
  }
  for (const sub of ["lib", "renderer"]) {
    const directory = join(root, sub)
    if (existsSync(directory)) visit(directory)
  }
  return files
}

function checkApplication(root) {
  const modules = join(root, "node_modules")
  const offenders = []
  let scanned = 0
  for (const file of shippedSources(root)) {
    scanned += 1
    const body = readFileSync(file, "utf8")
    const seen = new Set()
    for (const match of body.matchAll(SPECIFIER)) {
      const specifier = match[1]
      if (specifier.startsWith(".") || specifier.startsWith("/") || specifier.startsWith("\0")) continue
      if (providedByRuntime(specifier)) continue
      if (specifier.startsWith("node:") || isBuiltin(specifier)) continue
      if (OPTIONAL.has(specifier) || seen.has(specifier)) continue
      seen.add(specifier)
      const directory = join(modules, packageName(specifier))
      if (!existsSync(directory) || !statSync(directory).isDirectory()) {
        offenders.push(`${relative(root, file)}: ${specifier}`)
      }
    }
  }
  return { offenders, scanned }
}

function checkHostDependencies(runtimeRoot, manifestPath) {
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"))
  const modules = join(runtimeRoot, "node_modules")
  const dependencies = Object.keys(manifest.dependencies ?? {})
  const offenders = []
  for (const name of dependencies) {
    if (!existsSync(join(modules, name))) offenders.push(name)
  }
  return { offenders, scanned: dependencies.length }
}

const [, , mode, ...rest] = process.argv
if (mode === "app" && rest.length === 1) {
  const { offenders, scanned } = checkApplication(rest[0])
  if (offenders.length > 0) {
    console.error(offenders.map(line => `    ${line}`).join("\n"))
    process.exit(1)
  }
  console.log(`  ok: every bare import in ${scanned} shipped shell files resolves`)
} else if (mode === "host" && rest.length === 2) {
  const { offenders, scanned } = checkHostDependencies(rest[0], rest[1])
  if (offenders.length > 0) {
    console.error(`    not linked: ${offenders.join(", ")}`)
    process.exit(1)
  }
  console.log(`  ok: all ${scanned} Host runtime dependencies are linked`)
} else {
  console.error("usage: desktop-coverage.mjs app <app-root> | host <runtime-root> <host-package.json>")
  process.exit(2)
}
