echo "-------- journalctl -b -1 -p 3..4 -------\n"
sudo journalctl -b -1 -p 3..4
echo "\n"
echo "--------  journalctl -b -1 --no-pager | grep -E 'amdgpu|reset|timeout|hang|MES' | tail -40 --------\n"
sudo journalctl -b -1 --no-pager | grep -E "amdgpu|reset|timeout|hang|MES" | tail -40
