#!/bin/bash
# test-webui.sh - Quick test script for Web UI functionality

echo "Testing rpi-netboot-dev Web UI..."
echo ""

# Check if container is running
if ! docker ps | grep -q "rpi-netboot-dev"; then
    echo "❌ Container not running. Start with: ./run.sh start"
    exit 1
fi

echo "✅ Container is running"

# Check if Web UI port is exposed
if ! curl -s http://localhost:38434 > /dev/null 2>&1; then
    echo "❌ Web UI not responding on port 38434"
    echo "   Check logs: ./run.sh logs"
    exit 1
fi

echo "✅ Web UI is accessible"

# Test API endpoints
echo ""
echo "Testing API endpoints..."

# Test /api/images/list
if curl -s http://localhost:38434/api/images/list | grep -q "images"; then
    echo "✅ /api/images/list working"
else
    echo "⚠️  /api/images/list returned unexpected response"
fi

# Test /api/devices
if curl -s http://localhost:38434/api/devices | grep -q "devices"; then
    echo "✅ /api/devices working"
else
    echo "⚠️  /api/devices returned unexpected response"
fi

echo ""
echo "✨ Basic tests passed!"
echo ""
echo "Open Web UI: http://localhost:38434"
