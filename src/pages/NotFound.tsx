import { Link } from "react-router-dom";
import { Layout } from "../components/Layout";

export function NotFound() {
  return (
    <Layout>
      <p className="eyebrow mb-3">404</p>
      <h1 className="font-mono text-2xl font-bold text-fg">{"// chapter not found"}</h1>
      <p className="mt-3 text-muted">
        That page has not been written yet, or the link is wrong.{" "}
        <Link to="/">Back to the index</Link>.
      </p>
    </Layout>
  );
}
