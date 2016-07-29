require('nn')
require("io")
require("os")
require("paths")
require("torch")
require("cutorch")
require("cunn")
dofile("word2vec.lua")

-- Default configuration
config = {}
config.model = "model/model" -- model path

cmd = torch.CmdLine()
cmd:option("-model", config.model)
params = cmd:parse(arg)

for param, value in pairs(params) do
    config[param] = value
end

-- Load the word2vec model and evaluate
m = torch.load(config.model)
m:print_sim_words_interactive(10)
