"use client";
import { useState } from "react";

export function Clicker({ label }) {
  const [count, setCount] = useState(0);
  return (
    <button data-clicker={label} onClick={() => setCount(count + 1)}>
      {label}: {count}
    </button>
  );
}
