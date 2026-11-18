import test from 'node:test';
import assert from 'node:assert/strict';
import {parseQueuePage} from '../src/utils/queuePagination.js';
test('queue stages have bounded independent pages without accepting malformed ranges',()=>{
 assert.deepEqual(parseQueuePage({page:'3',limit:'10'}),{page:3,limit:10,from:20,to:29});
 assert.equal(parseQueuePage({}).limit,25);
 for(const query of [{page:'0'},{page:'1.5'},{limit:'501'},{limit:'0'},{page:['1','2']}])assert.equal(parseQueuePage(query),null);
});
