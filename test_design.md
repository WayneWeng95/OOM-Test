Design an OOM killer experiment, we have 4 container (disable swap), each with one controller process spawning 4 similar process which grows memory to be killed in OOM. We check if the OOM killer kill the same one each time or not.

The generator process have hearbeat to the 4 spawning processes, if one is killed by OOM killer, it spwans another one, we check if the spawning pattern is the same. 