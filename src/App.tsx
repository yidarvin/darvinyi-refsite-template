import { MDXProvider } from "@mdx-js/react";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { mdxComponents } from "./components/mdxComponents";
import { Home } from "./pages/Home";
import { Chapter } from "./pages/Chapter";
import { NotFound } from "./pages/NotFound";

export default function App() {
  return (
    <MDXProvider components={mdxComponents}>
      <BrowserRouter>
        <Routes>
          <Route path="/" element={<Home />} />
          <Route path="/:slug" element={<Chapter />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
      </BrowserRouter>
    </MDXProvider>
  );
}
