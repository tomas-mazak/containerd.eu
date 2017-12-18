@:
		hugo
		rsync -avz --delete public/ containerd@netport.valec.net:www/

s server:
		hugo server -D
