export function jsonResponse(
  body: unknown,
  status: number,
  corsHeaders: Record<string, string> = {}
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'Content-Type': 'application/json',
      ...corsHeaders,
    },
  });
}

export function errorResponse(
  status: number,
  code: string,
  message: string,
  corsHeaders: Record<string, string> = {}
): Response {
  return jsonResponse({ status: 'error', code, message }, status, corsHeaders);
}
