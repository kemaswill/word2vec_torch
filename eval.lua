require('nn')
require("io")
require("os")
require("paths")
require("torch")
require("cutorch")
require("cunn")
dofile("word2vec.lua")

path_model = "model/model_sg_corpus.txt_fix_ns_bug"
m2 = torch.load(path_model)
--m2:print_sim_words({"the","he","can"},5)
m2:print_sim_words_interactive(10)
