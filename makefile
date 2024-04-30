
push:
	git add * && git commit -m "update" && git push

all:
	rm -f recipes.db
	rm -f recipes.db.new
	lua experiment.lua