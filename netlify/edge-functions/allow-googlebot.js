export default async (request, context) => {
  const ua = request.headers.get("user-agent") || "";

  if (ua.includes("Googlebot")) {
    // Rewrite directly to the static asset
    return context.rewrite(request.url);
  }

  return context.next();
};
