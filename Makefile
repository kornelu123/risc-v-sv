simulate:
	verilator --binary ./tb/top.sv -o out -f sources.f -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
	./obj_dir/out

clean:
	rm -rf obj_dir/
