import { accessSync, constants, realpathSync, statSync } from "node:fs";
import path from "node:path";

function reject() {
  throw new Error("Invalid credential-helper path.");
}

export function quotePosixShellWord(value) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    /[\u0000\r\n]/.test(value)
  ) {
    reject();
  }
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

export function buildCredentialHelperGitConfig(helperPath) {
  if (
    path.sep !== "/" ||
    typeof helperPath !== "string" ||
    !path.isAbsolute(helperPath) ||
    path.normalize(helperPath) !== helperPath
  ) {
    reject();
  }

  let resolved;
  let metadata;
  try {
    resolved = realpathSync(helperPath);
    metadata = statSync(resolved);
    accessSync(resolved, constants.X_OK);
  } catch {
    reject();
  }
  if (resolved !== helperPath || !metadata.isFile()) reject();

  const helperCommand = `!exec ${quotePosixShellWord(resolved)}`;
  return Object.freeze([
    "-c",
    "credential.helper=",
    "-c",
    `credential.helper=${helperCommand}`,
    "-c",
    "credential.useHttpPath=true",
    "-c",
    "http.followRedirects=false",
  ]);
}
