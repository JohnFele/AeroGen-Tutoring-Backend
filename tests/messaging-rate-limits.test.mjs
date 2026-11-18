import test from 'node:test';import assert from 'node:assert/strict';
import {isMessagingActivity} from '../src/middleware/rateLimit.middleware.js';
test('chat polling uses bounded messaging limits while other workspace operations retain their existing limits',()=>{
 for(const path of ['/api/v1/workspace/conversations','/api/v1/workspace/conversations/c2500000-0000-4000-8000-000000000001/messages?before=x','/api/v1/workspace/notification-summary'])assert(isMessagingActivity({originalUrl:path}));
 for(const path of ['/api/v1/workspace','/api/v1/workspace/tickets','/api/v1/workspace/billing','/api/v1/admin/data'])assert(!isMessagingActivity({originalUrl:path}));
});
