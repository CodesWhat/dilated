import { perform } from "./action";

export default async function Command() {
  await perform("start");
}
