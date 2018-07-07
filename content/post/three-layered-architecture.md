---
title: "Three Layered Architecture"
date: 2018-07-05T21:03:51-04:00
draft: false
tags: [api, api-design, design-guidelines, micro-services]
---

> Whatever good things we build end up building us.

Taking inspiration from the quote above; API design decisions should be driven by what precisely the API will link and what will be on either side of the interface. The architecture explained in this post is being popularized by Mulesoft API design architecture.


<img src="/images/post/layered-architecture.png" align="center" />
<br />

Let's explore this architecture and explain about what is the purpose of each layer and how are they interlinked.

### System layer
This is the foundation fo all of the APIs which is going to be build on top of it. This layer performs following roles:

* CRUD operations on datastores
* Proxy for external systems

The design for the system layer should be thought on reusability. In my scenario, I was using spring-jpa and spring-rest to create the system layer. All of my entities and domains instead of being in a project are developed as libraries and used as pom dependency.

This enabled me to share our source of truth of db schema and single point of change whenever changes are introduced in the underlying structure.

There is a always a discussion on creating internal proxies on external system instead of accessing them directly. This results into longer response time though the pros of this approach outweighs that. Having a proxy in front of external systems, enabled me to create a [canonical data model](https://vabs.github.io/2018/05/30/canonical-data-model/). This also helped in integration with process layer as calling any external system, there is common response parser module determining if the system-layer API send a valid output for not. 

For example:

```
{
  "status": {
    "code": 0,
    "requestId": "7ef44db8-4a6b-11e8-b4a2-877690b61fea",
    "message": ""
  },
  "data": {
   ...
  }
}
```

|Property|Description|
|---|---|
|code        | Predefined values across all system layer APIs|
|requestId   | Used for tracking a request across layers|
|message     | Human readable error messages|



### Process Layer
This is the layer which holds all the business logic and performs all the hefty logic.
The way I designed this layer was dividing the layer into 2 components.

* Business Logic
* Orchestration Logic    

<img src="/images/post/process-layer.png" align="center" />

The segregation of different API endpoints and logic happens when following Domain Driven Design. The approach helps in reusability and breaking down dependency graphs. The orchestration layer also helps in following the design closely with business rules. 

For example:

> Business Requirement: When a user registers for on the website do following things

> 1. Check if the user exists in the existing systems
> 2. Check the user against an multiple external identity service and prefill the information

Let's assume we have an registration API and Search API. The business logic for the search API will be reused here to meet the requirement in 2. The logic can be used as a dependency and since checking against _multiple external identity services_, the registration API business logic can perform it in parallel. 

The modularity introduced helps in quick development and low maintainability costs.


### Experience Layer
This layer is what is being exposed to the real world. This layer is customized as per the need of the product. If the consumer is a mobile application; the requirement of displaying information is limited. Hence consuming the process layer response and parsing it on the application side will be wasted logic. Instead creating an experience layer API for mobile application, only giving out the response adhering to the requirement is more easier. This also enables in controlling the HTTP verbs for the consumer without introducing security policies on process layer. 

In my approach; the experience layer API used are for creating various integrations. The consumer for me is 3 web-applications and 2 CRM systems. The requirement of information to be shown or edited from the consumers is very specific. If the systems are accessing the process layer; most of the information exposed is not of importance for them. So experience layers filters the information need; though still following the [canonical data model](https://vabs.github.io/2018/05/30/canonical-data-model/).  CRM needs to perform `CRUD` on information; where-as web-applications can do `CRU`. 



**Developing based on this architecture, my points to ponder are:**

1. Start with the system layer and try to make libraries where required for maximum reusability.
2. [Canonical data model](https://vabs.github.io/2018/05/30/canonical-data-model/) is an evolving requirement in any business. Try to define domains and always remember, CDM is for transport; doesn't necessarily should match the physical data structures.
3. Secure the APIs 
4. Don't create dependency graphs [HTTP calls] on process layer between APIs, should be handled in reusing business logic.
5. Design idempotent, generic and standalone process and system layer.


Please ask if you have any questions in comments below.