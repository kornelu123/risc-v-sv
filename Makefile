simulate:
	verilator --binary ./tb/top.sv -o out -f sources.f --top-module t -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -DTESTFILE_PATH='"./test/test.bin"'
	./obj_dir/out

clean:
	rm -rf obj_dir/
