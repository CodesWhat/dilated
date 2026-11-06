import { getPreferenceValues, showHUD, showToast, Toast } from "@raycast/api";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  commandArguments,
  runDilated,
  statusDescription,
  type Command,
} from "./cli";

export async function perform(
  command: Command,
  minutes?: string,
): Promise<void> {
  try {
    const configured = getPreferenceValues<{
      cliPath?: string;
    }>().cliPath?.trim();
    const path = configured || join(homedir(), ".local", "bin", "dilated");
    const reply = await runDilated(path, commandArguments(command, minutes));
    switch (command) {
      case "status":
        await showHUD(statusDescription(reply));
        break;
      case "stop":
        await showHUD("Awake sessions stopped. Automation paused.");
        break;
      case "start":
        await showHUD("Awake until stopped.");
        break;
      case "hold":
        await showHUD(`Awake for ${minutes} minutes.`);
        break;
    }
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Dilated",
      message: error instanceof Error ? error.message : String(error),
    });
  }
}
