import { mount } from "svelte";
import "../styles/base.css";
import "./flash.css";
import Flash from "./Flash.svelte";

mount(Flash, { target: document.getElementById("app")! });
