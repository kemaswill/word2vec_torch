cmd="th main.lua -corpus text8 -window 3 -dim 100 -minfreq 10 -stream 1 -gpu 1 -mode sg -epochs 1"
#cmd="th main.lua -corpus text8 -window 3 -dim 100 -minfreq 1 -stream 1 -gpu 1 -mode cw -epochs 1"
#cmd="th main.lua -corpus text8 -window 3 -dim 100 -minfreq 1 -stream 1 -gpu 1 -mode cw -epochs 1"
echo $cmd
eval $cmd
