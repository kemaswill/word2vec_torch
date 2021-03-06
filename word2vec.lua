--[[
Class for word2vec with skipgram and negative sampling
--]]

require("sys")
require("nn")

local Word2Vec = torch.class("Word2Vec")

function Word2Vec:__init(config)
    self.tensortype = torch.getdefaulttensortype()
    self.mode = config.mode
    self.gpu = config.gpu -- 1 if train on gpu, otherwise cpu
    self.stream = config.stream -- 1 if stream from hard drive, 0 otherwise
    self.neg_samples = config.neg_samples
    self.minfreq = config.minfreq
    self.dim = config.dim
    self.criterion = nn.BCECriterion() -- logistic loss
    self.word = torch.IntTensor(1) 
    self.negatives = torch.IntTensor(1+self.neg_samples) 
    self.labels = torch.zeros(1+self.neg_samples); self.labels[1] = 1 -- first label is always pos sample
    self.window = config.window 
    self.lr = config.lr 
    self.min_lr = config.min_lr
    self.alpha = config.alpha
    self.table_size = config.table_size 
    self.vocab = {}
    self.index2word = {}
    self.word2index = {}
    self.v_contexts = torch.IntTensor(2 * self.window)
    self.total_count = 0
end

-- move to cuda
function Word2Vec:cuda()
    require("cunn")
    require("cutorch")
    cutorch.setDevice(1)
    self.word = self.word:cuda()
    self.negatives = self.negatives:cuda()
    self.v_contexts = self.v_contexts:cuda()
    self.labels = self.labels:cuda()
    self.criterion:cuda()
    self.w2v:cuda()
end

-- Build vocab frequency, word2index, and index2word from input file
function Word2Vec:build_vocab(corpus)
    print("Building vocabulary...")
    local start = sys.clock()
    local f = io.open(corpus, "r")
    local n = 1
    for line in f:lines() do
        for _, word in ipairs(self:split(line)) do
	    self.total_count = self.total_count + 1
	    if self.vocab[word] == nil then
	        self.vocab[word] = 1	 
            else
	        self.vocab[word] = self.vocab[word] + 1
	    end
        end
        n = n + 1
    end
    f:close()
    -- Delete words that do not meet the minfreq threshold and create word indices
    for word, count in pairs(self.vocab) do
    	if count >= self.minfreq then
     	    self.index2word[#self.index2word+1] = word
            self.word2index[word] = #self.index2word	    
    	else
	    self.vocab[word] = nil
        end
    end
    self.vocab_size = #self.index2word
    print(string.format("%d words and %d sentences processed in %.2f seconds.", self.total_count, n, sys.clock() - start))
    print(string.format("Vocab size after eliminating words occuring less than %d times: %d", self.minfreq, self.vocab_size))
    -- initialize word/context embeddings now that vocab size is known
    self:build_model()
end

-- Build Word2Vec Model, "sg" stand for SkipGram and "cw" stand for ContinuousBagOfWords
function Word2Vec:build_model()
    if self.mode == "sg" then
        self.word_vecs = nn.LookupTable(self.vocab_size, self.dim) -- word embeddings
        self.context_vecs = nn.LookupTable(self.vocab_size, self.dim) -- context embeddings
        self.word_vecs:reset(0.25); self.context_vecs:reset(0.25) -- rescale N(0,1)
        self.w2v = nn.Sequential()
        self.w2v:add(nn.ParallelTable())
        self.w2v.modules[1]:add(self.context_vecs)
        self.w2v.modules[1]:add(self.word_vecs)
        self.w2v:add(nn.MM(false, true)) -- dot prod and sigmoid to get probabilities
        self.w2v:add(nn.Sigmoid())
        self.decay = (self.min_lr - self.lr) / (self.total_count * self.window)
    else
        self.context_vecs = nn.LookupTable(self.vocab_size, self.dim) -- word embeddings
        self.word_vecs = nn.LookupTable(self.vocab_size, self.dim) -- word embeddings
        self.sum_word = nn.Sequential()
	self.sum_word:add(self.word_vecs)
	self.sum_word:add(nn.Sum(1, self.dim))
	self.sum_word:add(nn.Reshape(1, self.dim))
	self.word_vecs:reset(0.25); self.context_vecs:reset(0.25) -- rescale N(0,1)
        self.w2v = nn.Sequential()
        self.w2v:add(nn.ParallelTable())
        self.w2v.modules[1]:add(self.context_vecs)
        self.w2v.modules[1]:add(self.sum_word)
        self.w2v:add(nn.MM(false, true)) -- dot prod and sigmoid to get probabilities
        self.w2v:add(nn.Sigmoid())
        self.decay = (self.min_lr - self.lr) / (self.total_count * self.window)
    end
end

-- Build a table of unigram frequencies from which to obtain negative samples
function Word2Vec:build_table()
    local start = sys.clock()
    local total_count_pow = 0
    print("Building a table of unigram frequencies... ")
    for _, count in pairs(self.vocab) do
    	total_count_pow = total_count_pow + count^self.alpha
    end   
    self.table = torch.IntTensor(self.table_size)
    local word_index = 1
    local word_prob = self.vocab[self.index2word[word_index]]^self.alpha / total_count_pow
    for idx = 1, self.table_size do
        self.table[idx] = word_index
        if idx / self.table_size > word_prob then
            word_index = word_index + 1
	    word_prob = word_prob + self.vocab[self.index2word[word_index]]^self.alpha / total_count_pow
        end
        if word_index > self.vocab_size then
            word_index = word_index - 1
        end
    end
    print(string.format("Done in %.2f seconds.", sys.clock() - start))
end

-- Train on word context pairs
function Word2Vec:train_pair(word, contexts)
    local p = self.w2v:forward({contexts, word})
    local loss = self.criterion:forward(p, self.labels)
    local dl_dp = self.criterion:backward(p, self.labels)
    self.w2v:zeroGradParameters()
    self.w2v:backward({contexts, word}, dl_dp)
    self.w2v:updateParameters(self.lr)
end

-- Sample negative contexts
function Word2Vec:sample_negatives(word)
    self.negatives[1] = word
    local i = 2
    while i <= self.neg_samples + 1 do
        neg_context = self.table[torch.random(self.table_size)]
        -- neg_context = torch.random(#self.index2word)
	if word ~= neg_context then
	    self.negatives[i] = neg_context
	    i = i + 1
	end
    end
end

-- Sample negative contexts for the CBOW architecture, this is
-- diffrent from the  Word2Vec:sample_negatives(word) function
-- since the negative samples should not be the same as the center
-- word as well as the context word.
function Word2Vec:sample_negatives_cw(word, lst_context)
    self.negatives[1] = word
    local i = 2
    while i <= self.neg_samples + 1 do
        neg_context = self.table[torch.random(self.table_size)]
        -- neg_context = torch.random(#self.index2word)
	flag = true
	if word == neg_context then flag = false end
	for j = 1, lst_context:size(1) do
	    idx = lst_context[j]
	    if idx == neg_context then flag = false end
	end
	if flag then
	    self.negatives[i] = neg_context
	    i = i + 1
	end
    end
end

-- Train on sentences that are streamed from the hard drive
-- Check train_mem function to train from memory (after pre-loading data into tensor)
function Word2Vec:train_stream(corpus)
    print("Training...")
    local start = sys.clock()
    local c = 0
    f = io.open(corpus, "r")
    for line in f:lines() do
        sentence = self:split(line)
        for i, word in ipairs(sentence) do
	    word_idx = self.word2index[word]
	    if word_idx ~= nil then -- word exists in vocab
    	        local reduced_window = torch.random(self.window) -- pick random window size
		self.word[1] = word_idx -- update current word
                for j = i - reduced_window, i + reduced_window do -- loop through contexts
	            local context = sentence[j]
		    if context ~= nil and j ~= i then -- possible context
		        context_idx = self.word2index[context]
			if context_idx ~= nil then -- valid context
  		            self:sample_negatives(context_idx) -- update pos/neg contexts
			    self:train_pair(self.word, self.negatives) -- train word context pair
			    c = c + 1
			    self.lr = math.max(self.min_lr, self.lr + self.decay) 
			    if c % 100000 ==0 then
			        print(string.format("%d words trained in %.2f seconds. Learning rate: %.4f", c, sys.clock() - start, self.lr))
			    end
			end
		    end
                end		
	    end
	end
    end
end

-- Train on sentences that are streamed from the hard drive
-- Check train_mem function to train from memory (after pre-loading data into tensor)
function Word2Vec:train_stream_cw(corpus)
    print("Training...")
    local start = sys.clock()
    local c = 0
    f = io.open(corpus, "r")
    for line in f:lines() do
	sentence = self:split(line)
	cnt_word = 0
	for ii = 1, #sentence do
	    if self.word2index[sentence[ii]] ~= nil then cnt_word = cnt_word + 1 end
	end
	if cnt_word > 2 * self.window + 1 then 
	    for i, word in ipairs(sentence) do
	        word_idx = self.word2index[word]
	        if word_idx ~= nil then
		    self.word[1] = word_idx
		    self.v_contexts:fill(0)
		    self.v_contexts_word_debug = {}
		    window_acc = 2
		    v_context_idx = 1
		    while self.v_contexts[#self.v_contexts] == 0 do
			window_size_cur = math.floor(window_acc / 2)
			if window_acc % 2 == 0 then window_idx = i - window_size_cur else window_idx = i + window_size_cur end
			window_acc = window_acc + 1
			local context = sentence[window_idx]
		        if context ~= nil then
		            context_idx = self.word2index[context]
		            if context_idx ~= nil then
			        self.v_contexts[v_context_idx] = context_idx
				self.v_contexts_word_debug[v_context_idx] = context
				v_context_idx = v_context_idx + 1
			    end
			end
		    end
		    self:sample_negatives_cw(word_idx, self.v_contexts)
		    self:train_pair(self.v_contexts, self.negatives)
		    c = c + 1
		    self.lr = math.max(self.min_lr, self.lr + self.decay) 
		    if c % 100000 ==0 then
			print(string.format("%d words trained in %.2f seconds. Learning rate: %.4f", c, sys.clock() - start, self.lr))
		    end
                end
            end
        end
    end
end

-- Row-normalize a matrix
function Word2Vec:normalize(m)
    m_norm = torch.zeros(m:size())
    for i = 1, m:size(1) do
    	m_norm[i] = m[i] / torch.norm(m[i])
    end
    return m_norm
end

-- Return the k-nearest words to a word or a vector based on cosine similarity
-- w can be a string such as "king" or a vector for ("king" - "queen" + "man")
function Word2Vec:get_sim_words(w, k)
    if self.word_vecs_norm == nil then
	if self.mode == 'cw' then
	    self.word_vecs_norm = self:normalize(self.context_vecs.weight:double())
        else
	    self.word_vecs_norm = self:normalize(self.word_vecs.weight:double())
	end
    end
    if type(w) == "string" then
        if self.word2index[w] == nil then
	   print("'"..w.."' does not exist in vocabulary.")
	   return nil
	else
            w = self.word_vecs_norm[self.word2index[w]]
	end
    end
    local sim = torch.mv(self.word_vecs_norm, w)
    sim, idx = torch.sort(-sim)
    local r = {}
    for i = 1, k do
        r[i] = {self.index2word[idx[i]], -sim[i]}
    end
    return r
end

-- print similar words
function Word2Vec:print_sim_words(words, k)
    for i = 1, #words do
    	r = self:get_sim_words(words[i], k)
	if r ~= nil then
   	    print("-------"..words[i].."-------")
	    for j = 1, k do
	        print(string.format("%s, %.4f", r[j][1], r[j][2]))
	    end
	end
    end
end

-- print similar words in an interactive way
function Word2Vec:print_sim_words_interactive(k)
    print("Please input the words")
    while true do
        local line = io.read()
        if line == nil then break end
        if self.word2index[line] == nil then 
            print(string.format("%s is not in the vocabulary", line))
        else
            r = self:get_sim_words(line, k)
            for j = 1, k do
                print(string.format("%s, %.4f", r[j][1], r[j][2]))
            end
        end
    end
end

-- split on separator
function Word2Vec:split(input, sep)
    if sep == nil then
        sep = "%s"
    end
    local t = {}; local i = 1
    for str in string.gmatch(input, "([^"..sep.."]+)") do
        t[i] = str; i = i + 1
    end
    return t
end

-- pre-load data as a torch tensor instead of streaming it. this requires a lot of memory, 
-- so if the corpus is huge you should partition into smaller sets
function Word2Vec:preload_data(corpus)
    -- In SkipGram, contexts means a word around the center word and #self.neg_samples negative samples
    -- In ContinuousBagOfWords, contexts means the 2*reduced_window words around the center word
    print("Preloading training corpus into tensors (Warning: this takes a lot of memory)")
    local start = sys.clock()
    local c = 0
    f = io.open(corpus, "r")
    self.train_words = {}; self.train_contexts = {}
    for line in f:lines() do
        sentence = self:split(line)
        cnt_word = 0
        for ii = 1, #sentence do
	    if self.word2index[sentence[ii]] ~= nil then cnt_word = cnt_word + 1 end
        end
        for i, word in ipairs(sentence) do
	    word_idx = self.word2index[word]
	    if word_idx ~= nil then -- word exists in vocab
    	        local reduced_window = torch.random(self.window) -- pick random window size
		self.word[1] = word_idx -- update current word
		if self.mode == "sg" then
                    for j = i - reduced_window, i + reduced_window do -- loop through contexts
	                local context = sentence[j]
		        if context ~= nil and j ~= i then -- possible context
		            context_idx = self.word2index[context]
			    if context_idx ~= nil then -- valid context
			        c = c + 1
  		                self:sample_negatives(context_idx) -- update pos/neg contexts
			        if self.gpu == 1 then
			            self.train_words[c] = self.word:clone():cuda()
			            self.train_contexts[c] = self.negatives:clone():cuda()
			        else
				    self.train_words[c] = self.word:clone()
				    self.train_contexts[c] = self.negatives:clone()
			        end
			    end
		        end
	            end
                elseif self.mode == "cw" and cnt_word > 2 * self.window + 1 then
		    c = c + 1
		    self.v_contexts:fill(0)
		    window_acc = 2
		    v_context_idx = 1
		    while self.v_contexts[#self.v_contexts] == 0 do -- this while is used to collect 2 * window context words around the center word
		        window_size_cur = math.floor(window_acc / 2)
			if window_acc % 2 == 0 then window_idx = i - window_size_cur else window_idx = i + window_size_cur end
			window_acc = window_acc + 1
			local context = sentence[window_idx]
			if context ~= nil then --possible context
		            context_idx = self.word2index[context]
		            if context_idx ~= nil then -- valid context
			        self.v_contexts[v_context_idx] = context_idx
				v_context_idx = v_context_idx + 1
			    end
			end
		    end
		    self:sample_negatives_cw(word_idx, self.v_contexts) -- update pos.neg contexts
		    if self.gpu == 1 then
		        self.train_words[c] = self.v_contexts:clone():cuda()
			self.train_contexts[c] = self.negatives:clone():cuda()
		    else
	      	        self.train_words[c] = self.v_contexts:clone()
		        self.train_contexts[c] = self.negatives:clone()
		    end
		end
            end
	end
    end
    print(string.format("%d word-contexts processed in %.2f seconds", c, sys.clock() - start))
end

-- train from memory. this is needed to speed up GPU training
function Word2Vec:train_mem()
    local start = sys.clock()
    print("#self.train_words")
    print(#self.train_words)
    for i = 1, #self.train_words do
        self:train_pair(self.train_words[i], self.train_contexts[i])
	self.lr = math.max(self.min_lr, self.lr + self.decay)
	if i % 100000 == 0 then
            print(string.format("%d words trained in %.2f seconds. Learning rate: %.4f", i, sys.clock() - start, self.lr))
	end
    end    
end

-- train the model using config parameters
function Word2Vec:train_model(corpus)
    if self.gpu == 1 then
        self:cuda()
    end
    if self.stream == 1 then
	if self.mode == 'sg' then
            self:train_stream(corpus)
        elseif self.mode == 'cw' then
            self:train_stream_cw(corpus)
	end
    else 
        self:preload_data(corpus)
	self:train_mem()
    end
end

-- save model to disc
function Word2Vec:save_model(path)
    torch.save(path, self)
end

-- save vectors for each word to disc
function Word2Vec:save_vector(path)
    if self.word_vecs_norm == nil then
        self.word_vecs_norm = self:normalize(self.word_vecs.weight:double())
    end
    t = {}
    for i = 1, self.vocab_size do
        word = self.index2word[i]
        v = self.word_vecs_norm[i]
        t[word] = v
    end
    torch.save(path, t)
end
