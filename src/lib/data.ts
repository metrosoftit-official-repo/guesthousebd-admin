// NOTE: This is where you could wire up your own data providers:
// GraphQL, Databases, REST APIs, CDNs, proxies, S3, Matrix, IPFS, you name it…

export function url(path = '') {
	return path ? `/admin/${path}` : '/admin';
}

export function asset(path: string) {
	return `https://flowbite-admin-dashboard.vercel.app/${path}`;
}
