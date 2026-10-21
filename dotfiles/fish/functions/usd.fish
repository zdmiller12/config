function usd --description "Wrapper for OpenUSD installation"
    begin
        set -l USD_PATH $HOME/usd/python3.12/
        set -l BIN_PATH $USD_PATH/bin/

        fish_add_path -aP $BIN_PATH
        set -lx PYTHONPATH $USD_PATH/lib/python/

        env -C $BIN_PATH $argv
    end
end
