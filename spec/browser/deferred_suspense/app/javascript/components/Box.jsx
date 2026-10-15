"use client";
import { useState } from "react";

// Story 19-2 (AC8.1) — a client component with state, holding ERB children.
export function Box({ children }) {
  const [count, setCount] = useState(0);
  return (
    <section data-box="">
      <button data-box-count="" onClick={() => setCount(count + 1)}>box: {count}</button>
      {children}
    </section>
  );
}
