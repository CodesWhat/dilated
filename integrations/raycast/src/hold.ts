import type { LaunchProps } from "@raycast/api";
import { perform } from "./action";

export default async function Command({
  arguments: args,
}: LaunchProps<{ arguments: { minutes: string } }>) {
  await perform("hold", args.minutes);
}
