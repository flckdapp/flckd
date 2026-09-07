import "@radix-ui/themes/styles.css";
import "./styles.css";

import { Theme } from "@radix-ui/themes";
import { createRoot } from "react-dom/client";

import { App } from "./app";

const root = document.getElementById("root");
if (root === null) throw new Error("#root is missing from index.html");

createRoot(root).render(
  <Theme
    appearance="dark"
    accentColor="teal"
    grayColor="slate"
    radius="medium"
    panelBackground="solid"
  >
    <App />
  </Theme>,
);
