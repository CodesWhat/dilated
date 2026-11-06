import { execFile } from "node:child_process";

export type Command = "start" | "stop" | "status" | "hold";
export interface Reply {
  ok: boolean;
  id?: string;
  message?: string;
  code?: string;
  snapshot?: { holds: { label: string }[]; automationPaused: boolean };
}

export function commandArguments(command: Command, minutes?: string): string[] {
  switch (command) {
    case "start":
      return ["on", "--label", "Raycast", "--json"];
    case "stop":
      return ["off", "--json"];
    case "status":
      return ["status", "--json"];
    case "hold":
      if (
        !minutes ||
        !/^[1-9][0-9]*$/.test(minutes) ||
        !Number.isSafeInteger(Number(minutes))
      ) {
        throw new Error("Enter a positive whole number of minutes.");
      }
      return ["on", "--for", `${minutes}m`, "--label", "Raycast", "--json"];
  }
}

function parseReply(output: string): Reply {
  let value: unknown;
  try {
    value = JSON.parse(output);
  } catch {
    throw new Error(
      "Dilated returned an invalid response. Update the app and its command line tool.",
    );
  }
  if (
    typeof value !== "object" ||
    value === null ||
    !("ok" in value) ||
    typeof value.ok !== "boolean"
  ) {
    throw new Error(
      "Dilated returned an invalid response. Update the app and its command line tool.",
    );
  }
  const fields = value as Record<string, unknown>;
  for (const field of ["message", "code", "id"] as const) {
    if (field in fields && typeof fields[field] !== "string") {
      throw new Error("Dilated returned an invalid response.");
    }
  }
  return value as Reply;
}

export function runDilated(
  cliPath: string,
  args: readonly string[],
): Promise<Reply> {
  return new Promise((resolve, reject) => {
    execFile(
      cliPath,
      [...args],
      { encoding: "utf8", timeout: 8000, maxBuffer: 1024 * 1024 },
      (error, stdout, stderr) => {
        if (error?.code === "ENOENT" || error?.code === "EACCES") {
          reject(
            new Error(
              "Open Dilated Settings and install the command line tool, or check the CLI Path preference.",
            ),
          );
          return;
        }
        if (error?.killed) {
          reject(
            new Error(
              "Dilated did not respond in time. Check the app before trying again.",
            ),
          );
          return;
        }
        try {
          const reply = parseReply(stdout);
          if (!reply.ok)
            throw new Error(
              reply.message ??
                `Dilated rejected the request (${reply.code ?? "unknown"}).`,
            );
          if (error)
            throw new Error(
              stderr.trim() || "Dilated could not complete the request.",
            );
          resolve(reply);
        } catch (failure) {
          reject(failure);
        }
      },
    );
  });
}

export function statusDescription(reply: Reply): string {
  const snapshot = reply.snapshot;
  if (
    !snapshot ||
    !Array.isArray(snapshot.holds) ||
    typeof snapshot.automationPaused !== "boolean" ||
    !snapshot.holds.every(
      (hold) =>
        typeof hold === "object" &&
        hold !== null &&
        typeof hold.label === "string",
    )
  ) {
    throw new Error("Dilated returned an invalid response for status.");
  }
  const count = snapshot.holds.length;
  const names = snapshot.holds
    .slice(0, 3)
    .map((hold) => hold.label)
    .join(", ");
  const active =
    count === 0
      ? "No active holds"
      : `${count} active hold${count === 1 ? "" : "s"}: ${names}${count > 3 ? ", …" : ""}`;
  return `${active}. Automation ${snapshot.automationPaused ? "paused" : "running"}.`;
}
