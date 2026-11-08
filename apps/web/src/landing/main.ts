import { mount } from "svelte";
import "../styles/base.css";
import Landing from "./Landing.svelte";

mount(Landing, { target: document.getElementById("app")! });
