all:
	rm -f recipes.db
	rm -f recipes.db.new
	lua experiment.lua

push:
	git add * && git commit -m "update" && git push

emuload:
	cp *.lua "./emulator/4ae06751-5b25-4bb6-84f6-e818d23f304a/home/" # comp1
	cp *.lua "./emulator/e31822f7-5571-4469-afea-6b99fcde0730/home/" # comp2
