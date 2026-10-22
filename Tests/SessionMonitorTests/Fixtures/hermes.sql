CREATE TABLE sessions(id TEXT,title TEXT,model TEXT,billing_provider TEXT,source TEXT,started_at REAL,ended_at REAL,end_reason TEXT,parent_session_id TEXT,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,estimated_cost_usd REAL,actual_cost_usd REAL,cost_source TEXT,last_activity_at REAL,last_activity_description TEXT);
CREATE TABLE messages(id INTEGER,session_id TEXT,role TEXT,content TEXT,timestamp REAL,finish_reason TEXT);
INSERT INTO sessions VALUES('parent','Synthetic parent','example-model','example-provider','cli',100,200,'compression',NULL,10,5,0,NULL,NULL,0.01,NULL,'fixture',200,'Synthetic compression');
INSERT INTO sessions VALUES('continuation','Synthetic continuation','example-model','example-provider','cli',200,NULL,NULL,'parent',20,5,0,NULL,NULL,NULL,0,'fixture',300,'Synthetic activity');
INSERT INTO sessions VALUES('worker','Synthetic worker','example-model','example-provider','subagent',250,350,'completed','continuation',30,5,10,0,2,0.02,0.01,'fixture',350,'Synthetic completion');
INSERT INTO messages VALUES(1,'worker','assistant','Synthetic worker result.',350,'stop');
