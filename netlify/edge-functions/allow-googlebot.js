export default async (request, context) => {
  const ua = request.headers.get("user-agent") || "";
  if (ua.includes("Googlebot")) {
    return fetch(request);
  }
  return context.next();
};
