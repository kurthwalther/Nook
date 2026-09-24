#!/bin/zsh
# Llama una herramienta del MCP de desarrollo de Nook: kurth/mcp.sh <herramienta> ['{"arg": …}']
# El token se lee del archivo de Nook; nunca se copia a otro lado.
TOKEN=$(cat "$HOME/Library/Application Support/com.gstudios.nook/dev-mcp-token")
ARGS=${2:-'{}'}
curl -s -X POST http://127.0.0.1:47823/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$ARGS}}" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); res=r.get("result",r); [print(c["text"]) for c in res.get("content",[])] if "content" in res else print(json.dumps(res,indent=1))'
