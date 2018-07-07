---
title: "API Design Guidelines"
date: 2018-06-01T08:00:22-04:00
draft: false
tags: [api, api-design, design-guidelines, micro-services]
---

# ``` All good things must come to an api endpoint ```

Most of the real world application these days work by calling some sort of API to display or process data. API led connectivity has increased the pace of development. It is very similar to putting lego blocks together to build something useful.

With the evolution of API, there are 2 major principles which drives the success

1. **Platform Agnostic**: A client should be able to call the API, regardless of how the API is implemented internally. The complexity should be hidden and the contract between the API and the client should define the mechanism of data exchange.

2. **Scalability**: An API should be able to scale without independent of client application dependency. The new functionality should be exposed and easily discoverable to the client.


----------


## **Representational State Transfer API (REST API)**
In 2000, Roy Fielding in his [dissertation](https://www.ics.uci.edu/~fielding/pubs/dissertation/top.html "Architectural Styles and
the Design of Network-based Software Architectures") laid the foundation for REST architecture. REST is independent of any underlying protocol and is not necessarily tied to HTTP. However, most common REST implementations use HTTP as the application protocol, and this guide focuses on designing REST APIs for HTTP.


The following outlines designing a REST API for Web Services Architecture.

1.	[API Endpoint] (#api-endpoint)
2.	[Authentication] (#authentication)
3.	[Caching] (#caching)
4.	[HTTP Methods (verbs)] (#http-verbs)
5.	[HTTP Response Codes] (#response-codes)
6.	[Query Parameters] (#query-params)
7.	[Versioning] (#versioning)
8.	[Checklist] (#checklist)



>### **API Endpoint** {#api-endpoint}
The endpoint should have following features:

* It should be friendly to developer and be explored via browser / rest client address bar
* It should be simple, consistent and intuitive to make adoption easy
* It should provide flexibility for getting the data as required
* It should be concrete names because Cool URIs never change. 



---
>### **Authentication** {#authentication}
The endpoint should be always authenticated to prevent from automated attacks. There are multiple ways of authenticating an endpoint. 

* Token Based Authorization:
    In token based authorization, a token should be given to the given along with the call to the endpoint. The token can have the client signature and the expiry time. The service should first validate the token before doing the processing. If the token configuration is invalid, the service should return the error with response code as `401`.
* Key Based Authorization:
    A key is provided with the request by the client. The key can be unique to each client. This also helps in doing rate-limiting and statistics on the api calls. The key should be validated for the correct client and the expiration before the processing. If invalidated, the service should return the error with response code as `401`.

---
>### **Caching** {#caching}
A parameter should be given with the API definition to set / unset cache. The response for subsequent calls to the same resource should be based on the cache parameter. Default value for the parameter to be set as true. This helps in reducing the response time and also results in better performance.

The table below describes the expiry for cache.

|Expiry	    | Description|
|---        | ---        |
|x mins     |If external or third-party services is used|
|< x mins	|If the values fetched doesn't change frequently|
(where x is defined as per requirement)


----
>### **HTTP Methods (verbs)** {#http-verbs}

The following table explains the usage of HTTP verbs

<table>
<tr>
    <th> HTTP Verb </th>
    <th> Description </th>
    <th> Example </th>
</tr>
<tr>
    <td> get </td>
    <td> For retrieval </td>
    <td> <b>/test-service/test-resource/&lt;resourceId&gt;</b> </td>
</tr>
<tr>
    <td> post </td>
    <td> For persistance </td>
    <td> 
        <table>
            <tr>
                <th> Request Params </th>
                <th> Values </th>
            </tr>
            <tr>
                <td> Headers </td>
                <td> application/json <br /> application/xml </td>
            </tr>
            <tr>
                <td> Body </td>
                <td> json_content <br /> xml_content </td>
            </tr>
            <tr>
                <td> Authorization </td>
                <td> Token <br /> API_KEY </td>
            </tr>
        </table>
    </td>
</tr>
<tr>
    <td> put </td>
    <td> For updating <br /> {For updating the complete object}</td>
    <td>
        <b>/test-service/test-resource/&lt;resourceID&gt; </b>
        <table>
             <tr>
                <th> Request Params </th>
                <th> Values </th>
            </tr>
            <tr>
                <td> Headers </td>
                <td> application/json <br /> application/xml </td>
            </tr>
            <tr>
                <td> Body </td>
                <td> json_content <br /> xml_content </td>
            </tr>
            <tr>
                <td> Authorization </td>
                <td> Token <br /> API_KEY </td>
            </tr>
        </table>
    </td>
</tr>
<tr>
    <td> patch </td>
    <td> For partial updating </td>
    <td>
        <b>/test-service/test-resource/&lt;resourceID&gt; </b>
        <table>
             <tr>
                <th> Request Params </th>
                <th> Values </th>
            </tr>
            <tr>
                <td> Headers </td>
                <td> application/json <br /> application/xml </td>
            </tr>
            <tr>
                <td> Body </td>
                <td> json_content <br /> xml_content </td>
            </tr>
            <tr>
                <td> Authorization </td>
                <td> Token <br /> API_KEY </td>
            </tr>
        </table>
    </td>
</tr>
<tr>
    <td> delete </td>
    <td> For deleting </td>
    <td>
        <b>/test-service/test-resource/&lt;resourceID&gt; </b>
        <table>
             <tr>
                <th> Request Params </th>
                <th> Values </th>
            </tr>
            <tr>
                <td> Headers </td>
                <td> application/json <br /> application/xml </td>
            </tr>
            <tr>
                <td> Body </td>
                <td> json_content <br /> xml_content </td>
            </tr>
            <tr>
                <td> Authorization </td>
                <td> Token <br /> API_KEY </td>
            </tr>
        </table>
    </td>
</tr>
</table>



---
>### **HTTP Response Codes** {#response-codes}
Only standard response codes should be used for the services. The list below defines the allowed status codes

|Response Code|	Description|
|---|---|
|200	|For successful execution of request|
|201	|For successful creation of the new instance of object as in the request|
|204	|For successful processing of request. Should be used for delete requests|
|400	|Bad request. Because of invalid body or headers|
|401	|Unauthorized. Invalid authorization token|
|404	|Not Found. Resource not found|
|500	|Internal Server Error|



---
>### **Query Parameters** {#query-params}
Query parameters can be used for following operations.

|Operation|Description|
|---|---|
|Paging|	Required if the data returned by the service is more than 25 records at a time|
|Filtering|	Required if data is to be filtered based on arguments. <br />Example: /test-service/test-resource?**resourceFilter=test1**|
|Sorting|	Required if data is to be sorted in a particular order. <br />Example: /test-service/test-resource?**startDate=2016-01-1&endDate=2017-01-01**|
|Searching|	Required if data is to be retrieved based on query parameters but supports approximate matching|

---
>### **Versioning** {#versioning}
It's always advisable to version the APIs. This helps in maintaining code independence and new changes are introduced without breaking current functionality. There are various approaches to version the API.

* In URL:

    API can be versioned by appending the version number in the resource URL. <br />
    Example: /**v1.0**/ test-service

* In Header:

    Some users prefer version number to be passed in the headers when calling the API <br />
    Example: /test-service HEADER: **version: 1.0**

* As query parameter:
    API are also versioned by passing version number in the resource URL but as query parameter. <br />
    Example: /test-service?**version=1.0**



---
### **Checklist** {#checklist}

This is a personal checklist which I use to review the code for APIs.

1. HTTP Verbs are used for what they are defined as above. For example: A `POST` request should not do a partial update on the resource.
2. URI formatting 
    1. Use _plurals_ when returning collections in response. <br />
    Example: test-service/test-resources will return **all** resources related to the account.

    2. URI should not have trailing slash at the end of it  <br />
    Example: <br/>

        |URI Structure	|Allowed|
        |---|---|
        |/test-service/test-resource/&lt;resourceID&gt;/ | **wrong**  |
        |/test-service/test-resource/&lt;resourceID&gt;  |	 **correct**  |

    3. URI for every endpoint uses nouns instead of verbs. <br />
    Example:

        |URI Structure	|Allowed|
        |---|---|
        |get <br /> /test-service/gettestResource/&lt;resourceID&gt; |  **wrong**  |
        |post <br /> /saveDocuments| **wrong** |
        |get <br /> /test-service/test-resource/&lt;resourceID&gt;| **correct** |
        |post <br /> /documents| **correct** |

3. All messages are defined for HTTP response codes associated with the request. <br />
Example: Always define `200`, `400` and `500` responses.
4. Always define `Content-Type` header to explicit say about the responses.
5. Cache is used if possible
6. Don't expose underlying data model in response. Only return what is required or is business need.

<br />
### References:

For further reading I would like to suggest an article in Microsoft's technical documentation.
[Microsoft API Guidelines](https://docs.microsoft.com/en-us/azure/architecture/best-practices/api-design)