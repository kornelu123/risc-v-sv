simulate:
	verilator --binary ./tb/top.sv -o out -f sources.f --top-module t -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
	./obj_dir/out

clean:
	rm -rf obj_dir/
